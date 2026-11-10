// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockHyperCore - a small model of the HyperCore features Daffy uses
/// @notice Written for these tests from Hyperliquid's docs; NOT Hyperliquid's code. It models:
///         - CoreWriter actions queued during the EVM block and executed at the next block
///         - HYPE bridging both ways through 0x2222..2222 (EVM -> Core credited next block, and
///           invisible if the account doesn't exist yet)
///         - read precompiles: spot balance, oracle price, user exists, borrow state, position
///         - portfolio margin: HYPE spot is collateral (LTV 0.65, liquidation threshold 0.825,
///           liquidatable past a 0.95 ratio); USDC shortfalls show as borrowed USDC
///         - IOC limit orders filled at the oracle price if marketable, with taker fees
///         - HyperCore price format (5 significant figures, max decimals) and size decimals
///         - funding paid to or by shorts on demand
///         Not modelled: order books and slippage, borrow interest, partial liquidation.
contract MockHyperCore {
    uint32 public constant PERP = 159;
    uint32 public constant SPOT_ASSET = 10107;
    uint64 public constant HYPE = 150;
    uint64 public constant USDC = 0;
    uint8 public constant SZ_DEC = 2; // HYPE perp and spot size decimals
    uint8 public constant PM_CODE = 3; // test value for the "portfolio margin" abstraction
    address public constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;
    address public constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;

    uint256 public constant LTV_BPS = 6500;
    uint256 public constant LIQ_THRESHOLD_BPS = 8250; // 0.5 + 0.5 x LTV
    uint256 public constant LIQ_RATIO_BPS = 9500;
    uint256 public constant MAINT_BPS = 500; // maintenance margin on short notional
    uint256 public constant PERP_FEE_PPM = 450; // 0.045%
    uint256 public constant SPOT_FEE_PPM = 700; // 0.07%

    struct Account {
        bool exists;
        bool pm;
        uint256 hype; // 8 decimals
        int256 usdc; // 8 decimals; negative = borrowed
        int64 szi; // HYPE perp, 2 decimals
        uint64 entryNtl; // USD, 6 decimals
        uint256 latent; // HYPE bridged before the account existed (8 decimals)
    }

    struct Pending {
        address sender;
        bytes data; // empty = native bridge credit
        uint256 value;
    }

    mapping(address => Account) public acct;
    // v2: USDC supplied to lending (8 decimals), the EVM USDC token, spot sells seen
    mapping(address => uint256) public suppliedOf;
    mapping(address => uint256) public spotSells;
    mapping(address => uint256) public lowestSellPx; // oracle (raw) at the lowest-priced HYPE sell
    address public evmUsdc;
    bool public lendingReadBroken; // 0x811 reverts until the account first supplies (as on mainnet)
    bool public lendingReadBrokenForever; // stricter: it never starts working
    mapping(address => bool) public usedLending;
    struct UsdcCredit {
        address user;
        uint256 amount8;
    }
    UsdcCredit[] internal usdcQueue;
    address[] public users;
    mapping(address => bool) internal known;
    Pending[] internal queue;
    // mainnet: "order actions ... sent from CoreWriter are delayed onchain for a few seconds"
    struct Delayed {
        address sender;
        bytes data;
        uint256 at; // mock block it executes after
    }
    Delayed[] internal delayedOrders;
    uint256 public orderDelay; // extra blocks an order waits (0 = next block, as before)
    uint256 public mockBlock;

    function setOrderDelay(uint256 blocks) external {
        orderDelay = blocks;
    }

    uint64 public oracleRaw; // USD with 4 decimals (6 - SZ_DEC)
    bool public pmAvailable = true; // false: "set abstraction" from a contract does nothing
    bool public liquidated;
    uint256 public rejected; // actions HyperCore would refuse (bad format, margin, balance)

    // ------------------------------------------------------------------ test controls

    function setOracle(uint256 priceWad) external {
        oracleRaw = uint64(priceWad / 1e14);
    }

    function setExists(address u, bool e) external {
        _know(u);
        acct[u].exists = e;
        if (e && acct[u].latent > 0) {
            acct[u].hype += acct[u].latent;
            acct[u].latent = 0;
        }
    }

    function setLendingReadBroken(bool b) external {
        lendingReadBroken = b;
    }

    function setLendingReadBrokenForever(bool b) external {
        lendingReadBrokenForever = b;
    }

    function setEvmUsdc(address t) external {
        evmUsdc = t;
    }

    /// @notice Lending interest: every supplied balance grows by `ppm` parts per million.
    function accrueLending(uint256 ppm) external {
        for (uint256 i; i < users.length; i++) {
            suppliedOf[users[i]] += (suppliedOf[users[i]] * ppm) / 1e6;
        }
    }

    /// @notice CoreDepositWallet credit: USDC (8 decimals) to `user`'s spot balance next block.
    function queueUsdc(address user, uint256 amount8) external {
        usdcQueue.push(UsdcCredit(user, amount8));
    }

    /// @notice The account's value in USD (WAD), computed independently of Daffy.
    function isPm(address u) external view returns (bool) {
        return acct[u].pm;
    }

    function valueUsd(address u) external view returns (uint256) {
        Account storage a = acct[u];
        int256 usd8 = a.usdc + _upnl8(a) + int256(suppliedOf[u]);
        int256 v = usd8 * 1e10 + int256((a.hype * oracleRaw * 1e14) / 1e8);
        return v > 0 ? uint256(v) : 0;
    }

    function setPmAvailable(bool a) external {
        pmAvailable = a;
    }

    /// @notice Pay funding at `ratePpm` of each short's notional (positive: shorts receive).
    function payFunding(int256 ratePpm) external {
        for (uint256 i; i < users.length; i++) {
            Account storage a = acct[users[i]];
            if (a.szi >= 0) continue;
            int256 notional8 = int256(uint256(uint64(-a.szi)) * oracleRaw * 100); // 8 decimals
            a.usdc += (notional8 * ratePpm) / 1e6;
        }
        _checkLiquidations();
    }

    // ------------------------------------------------------------------ entry points (etched contracts)

    function queueAction(address sender, bytes calldata data) external {
        queue.push(Pending(sender, data, 0));
    }

    function queueNative(address sender) external payable {
        queue.push(Pending(sender, "", msg.value));
    }

    /// @notice What HyperCore does after an EVM block: credit bridges, run actions, check health.
    function nextBlock() external {
        uint256 n = queue.length;
        Pending[] memory items = new Pending[](n);
        for (uint256 i; i < n; i++) items[i] = queue[i];
        delete queue;
        // HYPE sent to the bridge (and USDC from the deposit wallet) is credited before CoreWriter actions
        for (uint256 i; i < n; i++) {
            if (items[i].data.length == 0) _credit(items[i].sender, items[i].value);
        }
        uint256 m = usdcQueue.length;
        for (uint256 i; i < m; i++) {
            _know(usdcQueue[i].user);
            acct[usdcQueue[i].user].usdc += int256(usdcQueue[i].amount8);
        }
        delete usdcQueue;
        mockBlock++;
        // orders that have waited long enough run first, in the order they were sent
        uint256 d = delayedOrders.length;
        if (d > 0) {
            Delayed[] memory held = new Delayed[](d);
            for (uint256 i; i < d; i++) held[i] = delayedOrders[i];
            delete delayedOrders;
            for (uint256 i; i < d; i++) {
                if (held[i].at <= mockBlock) _execute(held[i].sender, held[i].data);
                else delayedOrders.push(held[i]);
            }
        }
        for (uint256 i; i < n; i++) {
            if (items[i].data.length == 0) continue;
            bool isOrder = items[i].data.length >= 4 && uint8(items[i].data[3]) == 1 && uint8(items[i].data[2]) == 0
                && uint8(items[i].data[1]) == 0;
            if (isOrder && orderDelay > 0) delayedOrders.push(Delayed(items[i].sender, items[i].data, mockBlock + orderDelay));
            else _execute(items[i].sender, items[i].data);
        }
        _checkLiquidations();
    }

    function query(address precompile, bytes calldata input) external view returns (bytes memory) {
        uint160 p = uint160(precompile);
        if (p == 0x801) {
            (address u, uint64 token) = abi.decode(input, (address, uint64));
            Account storage a = acct[u];
            uint256 bal = token == HYPE ? a.hype : (a.usdc > 0 ? uint256(a.usdc) : 0);
            return abi.encode(uint64(bal), uint64(0), uint64(0));
        }
        if (p == 0x807) return abi.encode(oracleRaw);
        if (p == 0x810) return abi.encode(acct[abi.decode(input, (address))].exists);
        if (p == 0x811) {
            (address who0,) = abi.decode(input, (address, uint64));
            if (lendingReadBrokenForever || (lendingReadBroken && !usedLending[who0])) {
                // like mainnet: an erroring read precompile consumes all gas it was given
                assembly {
                    invalid()
                }
            }
            (address u, uint64 token) = abi.decode(input, (address, uint64));
            int256 usdc = acct[u].usdc;
            uint64 borrowed = token == USDC && usdc < 0 ? uint64(uint256(-usdc)) : 0;
            uint64 supplied = token == USDC ? uint64(suppliedOf[u]) : 0;
            return abi.encode(borrowed, borrowed, supplied, supplied);
        }
        if (p == 0x813) {
            (address u,) = abi.decode(input, (address, uint32));
            Account storage a = acct[u];
            return abi.encode(a.szi, a.entryNtl, int64(0), uint32(1), false);
        }
        revert("unknown precompile");
    }

    // ------------------------------------------------------------------ views for tests

    /// @notice The account's value in HYPE (18 decimals), computed independently of Daffy.
    function valueInHype(address u) external view returns (uint256) {
        Account storage a = acct[u];
        int256 usd8 = a.usdc + _upnl8(a);
        int256 v = int256(a.hype) + (usd8 * 1e4) / int256(uint256(oracleRaw));
        return v > 0 ? uint256(v) * 1e10 : 0;
    }

    function healthy(address u) external view returns (bool) {
        return _requirement8(acct[u]) * 1e4 <= _capacity8(acct[u], LTV_BPS);
    }

    // ------------------------------------------------------------------ internals

    function _know(address u) internal {
        if (!known[u]) {
            known[u] = true;
            users.push(u);
        }
    }

    function _credit(address u, uint256 wei18) internal {
        _know(u);
        uint256 amt = wei18 / 1e10;
        if (acct[u].exists) acct[u].hype += amt;
        else acct[u].latent += amt;
    }

    address internal _current;

    function _execute(address sender, bytes memory data) internal {
        _know(sender);
        _current = sender;
        if (uint8(data[0]) != 1) return _reject();
        uint24 kind = (uint24(uint8(data[1])) << 16) | (uint24(uint8(data[2])) << 8) | uint24(uint8(data[3]));
        bytes memory params = new bytes(data.length - 4);
        for (uint256 i; i < params.length; i++) params[i] = data[i + 4];
        Account storage a = acct[sender];
        if (!a.exists) return _reject();

        if (kind == 16) {
            (address user, uint8 code) = abi.decode(params, (address, uint8));
            if (user == sender && code == PM_CODE && pmAvailable) a.pm = true;
            return;
        }
        if (kind == 15) {
            (uint8 op, uint64 tok, uint64 wei8) = abi.decode(params, (uint8, uint64, uint64));
            if (tok != USDC) return _reject();
            if (op == 0) {
                if (a.usdc < 0) return _reject();
                uint256 amt = wei8 == 0 ? (a.usdc > 0 ? uint256(a.usdc) : 0) : wei8;
                if (a.usdc < int256(amt)) return _reject();
                a.usdc -= int256(amt);
                suppliedOf[sender] += amt;
                usedLending[sender] = true;
            } else {
                uint256 amt = wei8 == 0 ? suppliedOf[sender] : wei8;
                if (amt > suppliedOf[sender]) return _reject();
                suppliedOf[sender] -= amt;
                a.usdc += int256(amt);
            }
            return;
        }
        if (kind == 13) {
            (address dest,,,, uint64 token, uint64 amount) =
                abi.decode(params, (address, address, uint32, uint32, uint64, uint64));
            if (dest == USDC_SYSTEM && token == USDC) {
                if (int256(uint256(amount)) > a.usdc || evmUsdc == address(0)) return _reject();
                a.usdc -= int256(uint256(amount));
                IMintable(evmUsdc).mint(sender, uint256(amount) / 100);
                return;
            }
            if (dest != HYPE_SYSTEM || token != HYPE || amount > a.hype) return _reject();
            a.hype -= amount;
            if (!_ok(a, LTV_BPS)) {
                a.hype += amount;
                return _reject();
            }
            (bool sent,) = payable(sender).call{value: uint256(amount) * 1e10}("");
            require(sent, "evm transfer failed");
            return;
        }
        if (kind == 1) {
            (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif,) =
                abi.decode(params, (uint32, bool, uint64, uint64, bool, uint8, uint128));
            if (tif != 3 || sz == 0 || sz % 1e6 != 0) return _reject();
            if (asset == PERP) return _perp(a, isBuy, limitPx, sz, reduceOnly);
            if (asset == SPOT_ASSET) return _spot(a, isBuy, limitPx, sz);
            return _reject();
        }
        _reject();
    }

    function _perp(Account storage a, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly) internal {
        if (!_validPx(limitPx, 6 - SZ_DEC)) return _reject();
        uint256 px8 = uint256(oracleRaw) * 1e4;
        if (isBuy ? limitPx < px8 : limitPx > px8) return; // IOC not marketable: cancelled
        uint64 q = sz / 1e6; // contracts of 0.01 HYPE

        if (isBuy) {
            if (!reduceOnly || a.szi >= 0) return _reject(); // Daffy only ever buys to reduce a short
            uint64 open = uint64(-a.szi);
            if (q > open) q = open;
            uint64 avgEntry = a.entryNtl / open; // raw price units
            int256 pnl6 = int256(uint256(q)) * (int256(uint256(avgEntry)) - int256(uint256(oracleRaw)));
            a.usdc += pnl6 * 100 - int256(_fee8(q));
            a.entryNtl -= q * avgEntry;
            a.szi += int64(q);
            if (a.szi == 0) a.entryNtl = 0;
        } else {
            if (reduceOnly || a.szi > 0 || !a.pm) return _reject(); // no PM: no collateral for the short
            a.szi -= int64(q);
            a.entryNtl += q * oracleRaw;
            a.usdc -= int256(_fee8(q));
            if (!_ok(a, LTV_BPS)) {
                // refuse orders the account can't margin
                a.szi += int64(q);
                a.entryNtl -= q * oracleRaw;
                a.usdc += int256(_fee8(q));
                return _reject();
            }
        }
    }

    function _spot(Account storage a, bool isBuy, uint64 limitPx, uint64 sz) internal {
        if (!_validPx(limitPx, 8 - SZ_DEC)) return _reject();
        uint256 px8 = uint256(oracleRaw) * 1e4;
        if (isBuy ? limitPx < px8 : limitPx > px8) return;
        uint256 usd8 = (uint256(sz) * oracleRaw) / 1e4; // HYPE (8 dec) x price
        if (isBuy) {
            // without portfolio margin, spend only USDC the account has; with it, the shortfall is
            // borrowed against HYPE, within the 0.65 loan-to-value
            if (a.usdc < int256(usd8) && !a.pm) return _reject();
            a.usdc -= int256(usd8);
            a.hype += sz - (uint256(sz) * SPOT_FEE_PPM) / 1e6;
            if (a.usdc < 0 && !_ok(a, LTV_BPS)) {
                a.usdc += int256(usd8);
                a.hype -= sz - (uint256(sz) * SPOT_FEE_PPM) / 1e6;
                return _reject();
            }
        } else {
            if (sz > a.hype) return _reject();
            a.hype -= sz;
            a.usdc += int256(usd8 - (usd8 * SPOT_FEE_PPM) / 1e6);
            address who = _current;
            spotSells[who]++;
            if (lowestSellPx[who] == 0 || oracleRaw < lowestSellPx[who]) lowestSellPx[who] = oracleRaw;
        }
    }

    function _fee8(uint64 q) internal view returns (uint256) {
        return (uint256(q) * oracleRaw * 100 * PERP_FEE_PPM) / 1e6;
    }

    function _upnl8(Account storage a) internal view returns (int256) {
        if (a.szi >= 0) return 0;
        uint256 now6 = uint256(uint64(-a.szi)) * oracleRaw;
        return (int256(uint256(a.entryNtl)) - int256(now6)) * 100;
    }

    /// @dev USD (8 decimals) the account must cover: debt incl. unrealised loss + maintenance margin.
    function _requirement8(Account storage a) internal view returns (uint256) {
        int256 net = a.usdc + _upnl8(a);
        uint256 debt = net < 0 ? uint256(-net) : 0;
        uint256 maint = a.szi < 0 ? (uint256(uint64(-a.szi)) * oracleRaw * 100 * MAINT_BPS) / 1e4 : 0;
        return debt + maint;
    }

    /// @dev HYPE collateral in USD (8 decimals) times `bps` / 1e4, scaled by 1e4.
    function _capacity8(Account storage a, uint256 bps) internal view returns (uint256) {
        return (a.hype * oracleRaw * bps) / 1e4;
    }

    function _ok(Account storage a, uint256 bps) internal view returns (bool) {
        return _requirement8(a) * 1e4 <= _capacity8(a, bps);
    }

    function _checkLiquidations() internal {
        for (uint256 i; i < users.length; i++) {
            Account storage a = acct[users[i]];
            if (!a.pm || (a.szi == 0 && a.usdc >= 0)) continue;
            // liquidatable when requirement > 0.95 x collateral x liquidation threshold
            if (_requirement8(a) * 1e4 * 1e4 > _capacity8(a, LIQ_THRESHOLD_BPS) * LIQ_RATIO_BPS) liquidated = true;
        }
    }

    /// @dev At most 5 significant figures (integers always valid) and `maxDec` decimals; 1e8-scaled.
    function _validPx(uint64 px8, uint256 maxDec) internal pure returns (bool) {
        if (px8 == 0) return false;
        if (px8 % (10 ** (8 - maxDec)) != 0) return false;
        if (px8 % 1e8 == 0) return true;
        uint256 digits;
        for (uint256 v = px8; v > 0; v /= 10) digits++;
        return digits <= 5 || px8 % (10 ** (digits - 5)) == 0;
    }

    function _reject() internal {
        rejected++;
    }

    receive() external payable {}
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Etched at 0x3333..3333: forwards CoreWriter actions to the mock.
contract MockCoreWriter {
    MockHyperCore public immutable core;

    event RawAction(address indexed user, bytes data);

    constructor(MockHyperCore core_) {
        core = core_;
    }

    function sendRawAction(bytes calldata data) external {
        core.queueAction(msg.sender, data);
        emit RawAction(msg.sender, data);
    }
}

/// @notice Etched at 0x2222..2222: native HYPE sent here is bridged to the sender's HyperCore spot.
contract MockHypeSystem {
    MockHyperCore public immutable core;

    constructor(MockHyperCore core_) {
        core = core_;
    }

    receive() external payable {
        core.queueNative{value: msg.value}(msg.sender);
    }
}

/// @notice Etched at each precompile address: answers reads from the mock's state.
contract MockPrecompile {
    MockHyperCore public immutable core;

    constructor(MockHyperCore core_) {
        core = core_;
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        return core.query(address(this), input);
    }
}
