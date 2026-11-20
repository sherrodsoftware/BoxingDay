# Xcode Security Settings

Security build settings decisions for Boxing Day: the app and its unit-test bundle. The project is Swift only. First audited 2026-11-20.

## Enabled settings

- `ENABLE_ENHANCED_SECURITY`: Set at the project level, so both targets and any future ones inherit it.
- `com.apple.security.hardened-process` and `com.apple.security.hardened-process.enhanced-security-version-string` to `2`: In `Boxing Day/Boxing Day.entitlements`, which `CODE_SIGN_ENTITLEMENTS` points to in both of the app's configurations.
- `com.apple.security.hardened-process.hardened-heap`: The app.
- `com.apple.security.hardened-process.dyld-ro`: The app.
- `com.apple.security.hardened-process.platform-restrictions-string` to `2`: The app. Sparkle talks to its Installer and Downloader XPC services and its Updater app through XPC, which these restrictions allow; Boxing Day itself uses no raw Mach IPC. Installing a real update through Sparkle is the check that would surface a problem here.
- `com.apple.security.hardened-process.checked-allocations` with `com.apple.security.hardened-process.checked-allocations.soft-mode`: Hardware memory tagging on the app. It takes effect only on Macs with an M5 chip or later. Soft mode produces simulated crash reports instead of quitting; turn soft mode off once those have been reviewed and fixed.
- `ENABLE_HARDENED_RUNTIME`: Already on for the app before this audit. `scripts/release.sh` checks that the app and `Sparkle.framework` are signed with it.

## Disabled settings

- `ENABLE_POINTER_AUTHENTICATION` to `NO` on the Boxing Day target: Sparkle is linked as a prebuilt XCFramework that ships only `arm64` and `x86_64`, with no `arm64e` slice, and an `arm64e` app can't link it. Enhanced Security stays on for every other protection; only the `arm64e` slice is left out. Lift this override when Sparkle ships an `arm64e` slice. The test target inherits pointer authentication from the project, which is harmless because the test bundle runs inside the app.
- `ENABLE_HARDWARE_CHECKED_POINTER_ARITHMETIC_SLICE` to `NO` on the Boxing Day target: The `arm64e.x1` slice builds on pointer authentication, which is off for the same reason. Checked pointer arithmetic isn't available on the Mac anyway.

## Deferred

None.

## Not applicable

- Compiler, static analyzer, and clang-tidy warnings (`GCC_WARN_*`, `CLANG_WARN_*`, `CLANG_ANALYZER_SECURITY_*`, `CLANG_TIDY_*`): They apply to C-family code, and the project is Swift only.
- Additional diagnostic settings (`CLANG_WARN_SUSPICIOUS_IMPLICIT_CONVERSION`, `CLANG_ANALYZER_SECURITY_BUFFER_OVERFLOW_EXPERIMENTAL`, `CLANG_WARN_ASSIGN_ENUM`, `GCC_WARN_SIGN_COMPARE`): Also C-family only.
- `com.apple.security.hardened-process.checked-allocations.enforce-checked-pointer-arithmetic-overflow`: Checked pointer arithmetic is for iPhone, iPad, and Apple Watch, not the Mac.
- `ENABLE_C_BOUNDS_SAFETY` and `ENABLE_CPLUSPLUS_BOUNDS_SAFE_BUFFERS`: The project has no C or C++.
- Enhanced Security entitlements on Boxing DayTests: It's a unit-test bundle that runs inside the app, not a shipping product.
