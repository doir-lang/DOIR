import sys
from pathlib import Path

if len(sys.argv) != 2:
    print(f"Usage: {sys.argv[0]} <file>")
    sys.exit(1)

file_path = Path(sys.argv[1])

if not file_path.is_file():
    print(f"Error: '{file_path}' is not a valid file.")
    sys.exit(1)

data = file_path.read_bytes()

counter = 0
for byte in data:
    print(f"%{counter} : compiler.byte = 0x{byte:02x}")
    print(f"_ : compiler.byte = compiler.emit(%{counter})")
    counter += 1
