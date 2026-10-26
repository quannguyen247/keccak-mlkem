# 2026-10-26T14:42:29.852384135
import vitis

client = vitis.create_client()
client.set_workspace(path="Software")

platform = client.get_component(name="keccak_platform")
status = platform.build()

comp = client.get_component(name="keccak_test")
comp.build()

status = platform.build()

comp.build()

status = platform.build()

comp.build()

status = platform.build()

comp.build()

vitis.dispose()

