# 2026-10-26T02:42:24.382641092
import vitis

client = vitis.create_client()
client.set_workspace(path="Software")

platform = client.get_component(name="keccak_platform")
status = platform.update_hw(hw_design = "$COMPONENT_LOCATION/../../Implementation/project/keccak_soc_ila/keccak_system_wrapper.xsa")

vitis.dispose()

