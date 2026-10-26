# 2026-10-24T20:28:47.561017696
import vitis

client = vitis.create_client()
client.set_workspace(path="Software")

platform = client.create_platform_component(name = "keccak_platform",hw_design = "$COMPONENT_LOCATION/../../Implementation/project/keccak_soc_ila/keccak_system.xsa",os = "standalone",cpu = "psu_cortexa53_0",domain_name = "standalone_psu_cortexa53_0",no_boot_bsp = True,architecture = "64-bit",compiler = "gcc")

comp = client.create_app_component(name="keccak_test",platform = "$COMPONENT_LOCATION/../keccak_platform/export/keccak_platform/keccak_platform.xpfm",domain = "standalone_psu_cortexa53_0")

platform = client.get_component(name="keccak_platform")
status = platform.build()

comp = client.get_component(name="keccak_test")
comp.build()

vitis.dispose()

