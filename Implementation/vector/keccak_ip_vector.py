import hashlib, sys
from pathlib import Path

# Config parameters
VECTORS = Path(__file__).resolve().parent
MAX_MSG = 400
MAX_OUT = 400
RNG_SEED = 0x1A2B3C4D
MODES = {
    0: ("SHAKE128", 168, lambda m, n: hashlib.shake_128(m).digest(n)),
    1: ("SHAKE256", 136, lambda m, n: hashlib.shake_256(m).digest(n)),
    2: ("SHA3-256", 136, lambda m, n: hashlib.sha3_256(m).digest()),
    3: ("SHA3-512",  72, lambda m, n: hashlib.sha3_512(m).digest()),
}

# Xorshift32 PRNG to create random test cases
def xorshift32(s):
    s = (s ^ (s << 13)) & 0xFFFFFFFF
    s = (s ^ (s >> 17)) & 0xFFFFFFFF
    return (s ^ (s << 5)) & 0xFFFFFFFF

# Make one test case
def make(mode, msg, out_len):
    out = MODES[mode][2](msg, out_len)
    return mode, msg, out

# Generate test cases
def gen_cases(random_cases):
    for mode, (_, rate, _) in MODES.items():

        # Fixed cases
        yield make(mode, b"", 32)
        yield make(mode, b"abc", 32)

        # Edge cases: input boundary
        for mlen in (rate - 1, rate, rate + 1, 2 * rate + 3):
            yield make(mode, bytes((j * 29 + mlen * 7) & 0xFF for j in range(mlen)), 64)

        # Edge cases: output boundary
        if mode < 2:
            for olen in (rate, rate + 1, 2 * rate + 7):
                yield make(mode, b"XOF_TEST", olen)

    # Random cases
    s = RNG_SEED
    for _ in range(random_cases):
        s = xorshift32(s); mode = s % 4
        s = xorshift32(s); mlen = s % (MAX_MSG + 1)
        s = xorshift32(s); olen = (s % MAX_OUT) + 1
        mb = bytearray()
        for _ in range(mlen):
            s = xorshift32(s); mb.append(s & 0xFF)
        yield make(mode, bytes(mb), olen)

def main():
    if len(sys.argv) > 1 and sys.argv[1].lower() == "clear":
        for p in VECTORS.glob("keccak_ip_tv*"): p.unlink()
        print("Cleared vectors."); return 0

    base = len(list(gen_cases(0)))
    rnd_cases = max(0, int(sys.argv[1]) - base) if len(sys.argv) > 1 else 0
    cases = list(gen_cases(rnd_cases))

    # Write expected output, message, output length, message length, mode
    with open(VECTORS / "keccak_ip_tv.mem", "w") as f:
        for mode, msg, out in cases:
            exp_hex = out.ljust(MAX_OUT, b'\0')[::-1].hex()
            msg_hex = msg.ljust(MAX_MSG, b'\0')[::-1].hex()
            f.write(f"{exp_hex}{msg_hex}{len(out):04x}{len(msg):04x}{mode:02x}\n")

    # Write spec
    (VECTORS / "keccak_ip_tv_spec.txt").write_text(
        f"tv_count={len(cases)}\nmax_msg_bytes={MAX_MSG}\nmax_out_bytes={MAX_OUT}\n"
        f"base_cases={base}\nrandom_cases={rnd_cases}\n"
    )

    print(f"Generated {len(cases)} vectors. Spec: {VECTORS}/keccak_ip_tv_spec.txt")
    return 0

if __name__ == "__main__":
    sys.exit(main())