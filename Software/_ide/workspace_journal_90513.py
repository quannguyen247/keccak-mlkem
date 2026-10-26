# 2026-10-26T13:42:15.330928223
import vitis

client = vitis.create_client()
client.set_workspace(path="Software")

platform = client.get_component(name="keccak_platform")
status = platform.build()

comp = client.get_component(name="keccak_test")
comp.build()

vitis.dispose()

