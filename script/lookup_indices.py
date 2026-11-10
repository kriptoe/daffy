"""Print the HyperCore indices Deploy.s.sol needs. Usage: python3 script/lookup_indices.py [mainnet|testnet]"""
import json, sys, urllib.request

net = sys.argv[1] if len(sys.argv) > 1 else "mainnet"
url = "https://api.hyperliquid.xyz/info" if net == "mainnet" else "https://api.hyperliquid-testnet.xyz/info"

def info(t):
    req = urllib.request.Request(url, json.dumps({"type": t}).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))

perps = info("meta")["universe"]
perp = next(i for i, a in enumerate(perps) if a["name"] == "HYPE")
spot = info("spotMeta")
hype = next(t for t in spot["tokens"] if t["name"] == "HYPE")
usdc = next(t for t in spot["tokens"] if t["name"] == "USDC")
pair = next(p for p in spot["universe"] if p["tokens"] == [hype["index"], usdc["index"]])
print(f"HYPE_TOKEN={hype['index']}")
print(f"USDC_TOKEN={usdc['index']}")
print(f"PERP_INDEX={perp}")
print(f"SPOT_ASSET={10000 + pair['index']}")
print(f"SZ_DECIMALS={perps[perp]['szDecimals']}   # spot szDecimals: {hype['szDecimals']} (must match)")
