return {
    clj = function(...)
        local jdk = plugin(
            "https://raw.githubusercontent.com/dotcmdhq/plugins/e982851b6668d61fa27238be8a7194da424ce800/liberica_jdk.lua",
            "894a2f401f621060a4f8a7835d5f5dbf4681f2136c2fadc78e641ee40bc81495") {
            version = "25.0.2+12",
            sha256 = {
                linux = {
                    x64 = "8dc3f4451b0affe00a6d4da0aa2331240bf7d142a353ff529673501f8bd09c4a",
                    arm64 = "9bc4b2eb7be2b7d1e481bf83c6c86db5375b5e56925b083d3d4ef210dcf6e0b8"
                },
                macos = {
                    x64 = "461e34d4caac11f73aeceb7cd82b2818dae865727580651526b24cb14a1f0d85",
                    arm64 = "0795aa8b3631839a8ab41a94cb94ea56727fa62e2749919553d8965ab3d21b6f"
                },
                windows = {
                    x64 = "704e5d6ff0b6de67461d12403a9864d211fa9c64187efa185dfa70dfbb130f33",
                    arm64 = "db682beab88c4f186f05f558a2cfc08cf7b672eb5675f34bb2e7ec2b7504c275"
                }
            }
        }
        local clj = plugin(
            "https://raw.githubusercontent.com/dotcmdhq/plugins/e982851b6668d61fa27238be8a7194da424ce800/clj.lua",
            "42953ef089827a5981988e466005d494b0105320531a0fc436dc06bf75ba3d0b") {
            jdk = jdk,
            version = "1.12.6.1673",
            sha256 = {
                launcher = "49e8cf2de68709c1748a703906df2121b54c8371109d31bbb1d36dd6850b87fa",
                tools = "bb2f8a9f3fa94834813bd437b2a28b857c2f4b7267cb80168c0c6b910f883d4f"
            }
        }
        exec { clj, ... }
    end
}
