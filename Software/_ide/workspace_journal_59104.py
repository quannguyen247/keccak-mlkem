# 2026-10-26T12:06:02.340623490
import vitis

client = vitis.create_client()
client.set_workspace(path="Software")

platform = client.get_component(name="keccak_platform")
status = platform.build()

status = platform.build()

comp = client.get_component(name="keccak_test")
comp.build()

status = platform.build()

comp.build()

status = platform.build()

comp.build()

vitis.dispose()

