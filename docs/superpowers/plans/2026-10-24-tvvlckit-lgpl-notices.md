# Implementation Plan: TVVLCKit / LibVLC LGPL Release Notices and Framework Relinking

- **Date:** 2026-10-24
- **Target Path:** `docs/superpowers/plans/2026-10-24-tvvlckit-lgpl-notices.md`
- **Design Reference:** `docs/superpowers/specs/2026-10-24-playback-buffer-lgpl-and-remote-seek-design.md` (Topic 3: Section 4 & AC-LGPL-01..03)
- **Status:** Pending Review

---

## 1. Goal and Bounded Scope

Document open-source licensing terms for the bundled `TVVLCKit.xcframework` by appending accurate, inspected notices to `THIRD_PARTY_NOTICES.md` and providing source-code access terms and step-by-step framework re-linking instructions.

### Bounded Scope:
- **Inspect Setup Script Pin:** Bind all version claims to the pin defined in `scripts/setup_vlc.sh` (TVVLCKit 3.7.2, commit `3e42ae47`, LibVLC 3.0.x core, SHA256 `fa264c2eb17d648669d9d12b51e76e5b6769828354517d09b340387b30825f58`). Note that internal `Info.plist` may report generic bundle version `1.0`.
- **Inspect Upstream Archive / License Files:** Download or inspect the pinned archive (`TVVLCKit-3.7.2-3e42ae47-79128878.tar.xz`) to verify actual license files (`COPYING`, `COPYING.LIB`, module licenses).
- **Conditional Inventory Claims:** Declare the VideoLAN VLCKit project under LGPL version 2.1 (do not claim "or later" unless archive license proves it). Note that bundled modules and third-party dependencies remain conditional on an archive inventory. Do not make blanket uniform license claims across all bundled codecs/libraries.
- **Preserve Existing Notices:** Keep all existing notices in `THIRD_PARTY_NOTICES.md` intact (QuarkPan MIT license and quarkpan-rs reference notes). Append only.
- **Provide Exact Relinking Instructions:** Detail how a recipient can replace `Frameworks/TVVLCKit.xcframework` with an alternative build and regenerate the Xcode project using `python3 scripts/generate_xcode_project.py`.
- **Legal Disclaimer:** Explicitly state that documentation does not constitute legal advice or formal warranty of compliance.
- **Exclusions:** No modifications to episode title display, badge UI, or push to remote git repositories.

---

## 2. Architecture and Document Structure

```
THIRD_PARTY_NOTICES.md
├── [Preserved Existing Section 1: QuarkPan MIT License]
├── [Preserved Existing Section 2: quarkpan-rs Reference Note]
└── [Appended Section 3: VideoLAN TVVLCKit]
     ├── Component Metadata (Pinned version 3.7.2, LibVLC 3.0.x, archive SHA256)
     ├── License Inventory & Scope (LGPL-2.1 declaration, module inventory conditions)
     ├── Source Code Access Links (VLCKit repo, upstream LibVLC, archive URL, local scripts)
     ├── Instructions for Re-linking / Swapping Framework (scripts/generate_xcode_project.py)
     ├── Legal Disclaimer (No legal advice / compliance guarantee)
     └── Verbatim GNU Lesser General Public License (LGPL) Version 2.1 Full Text
```

---

## 3. Step-by-Step Implementation Plan

### Step 1: Inspect Setup Script and Archive Metadata
**Files to Inspect:**
- `scripts/setup_vlc.sh`
- `Frameworks/TVVLCKit.xcframework/Info.plist`
- `Frameworks/TVVLCKit.xcframework/tvos-arm64/TVVLCKit.framework/Info.plist`

1. **Inspection Commands:**
   ```bash
   grep -E 'TVVLCKIT_VERSION|TVVLCKIT_URL|EXPECTED_SHA256' scripts/setup_vlc.sh
   plutil -p Frameworks/TVVLCKit.xcframework/Info.plist
   plutil -p Frameworks/TVVLCKit.xcframework/tvos-arm64/TVVLCKit.framework/Info.plist
   ```
2. **Archive License Verification (if archive is cached or retrievable):**
   - Download/extract headers and license manifests from the pinned URL or inspect existing framework bundle for license files.
   - Record exact findings: confirm LGPL-2.1 text, confirm presence of sub-module licenses (e.g. ffmpeg, libebml, libass).
3. **Verify Constraints:**
   - Confirm binary plist reports `CFBundleShortVersionString` `1.0` while `setup_vlc.sh` pins `3.7.2` (commit `3e42ae47`).

---

### Step 2: Draft Append Content for `THIRD_PARTY_NOTICES.md`
**Files:**
- Prepare: `docs/superpowers/plans/notices_draft.md` (or directly in test verification)

1. **Draft Section Details:**
   - **Component Name:** TVVLCKit for tvOS
   - **Version:** 3.7.2 (LibVLC 3.0.x core, Git commit `3e42ae47`)
   - **Upstream Origin:** VideoLAN (`https://code.videolan.org/videolan/VLCKit`)
   - **Archive Distribution:** `https://download.videolan.org/cocoapods/prod/TVVLCKit-3.7.2-3e42ae47-79128878.tar.xz`
   - **Archive SHA256:** `fa264c2eb17d648669d9d12b51e76e5b6769828354517d09b340387b30825f58`
   - **License:** GNU Lesser General Public License, Version 2.1 (LGPLv2.1).
   - **Module Inventory Notice:** Specific modules bundled within LibVLC/TVVLCKit may carry distinct permissive or copyleft licenses (e.g., BSD, MIT, GPL/LGPL). Claims are strictly conditional on the verified archive contents.
   - **Source Code Access Statement:**
     Instructions on obtaining corresponding source code for the exact TVVLCKit release and build recipe.
   - **Framework Replacement and Relinking Guide:**
     1. Build or download an alternative binary of `TVVLCKit.xcframework`.
     2. Replace directory `Frameworks/TVVLCKit.xcframework`.
     3. Run `python3 scripts/generate_xcode_project.py` to re-link.
     4. Open `QuarkTheater.xcodeproj` and build for tvOS.
   - **Legal Disclaimer Notice:**
     "This notice is provided for informational and compliance transparency purposes and does not constitute formal legal counsel or an absolute compliance warranty."
   - **Full License Text:**
     Full, unmodified text of GNU Lesser General Public License, Version 2.1, February 1999.

---

### Step 3: Implement Automated Content Verification Test
**Files:**
- Create: `QuarkTheaterTests/ThirdPartyNoticesTests.swift`

1. **Write Test (RED):**
   - Test that `THIRD_PARTY_NOTICES.md` retains the exact original MIT notice and QuarkPan references.
   - Test that `THIRD_PARTY_NOTICES.md` contains the TVVLCKit 3.7.2 version string and commit hash `3e42ae47`.
   - Test that `THIRD_PARTY_NOTICES.md` contains the verbatim phrase "GNU LESSER GENERAL PUBLIC LICENSE" and "Version 2.1".
   - Test that instructions for `python3 scripts/generate_xcode_project.py` are present.
   - Test that no blanket license claim asserting all sub-modules share uniform licensing is present.
2. **Run Test:**
   - Execute: `xcodebuild test -scheme QuarkTheater -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:QuarkTheaterTests/ThirdPartyNoticesTests`
   - Expected: RED.
3. **Append to `THIRD_PARTY_NOTICES.md` (GREEN):**
   - Append the verified TVVLCKit section and full LGPL-2.1 text to `THIRD_PARTY_NOTICES.md` while keeping lines 1-30 completely intact.
4. **Run Test:**
   - Re-run command; verify tests pass GREEN.

---

### Step 4: Validate Relinking Script Compatibility
**Files:**
- Inspect: `scripts/generate_xcode_project.py`

1. **Test Verification:**
   - Run `python3 scripts/generate_xcode_project.py --check`
   - Verify that replacing or checking the framework path does not violate project structure expectations.
   - Verify expected exit code 0.

---

## 4. Risks and Edge Cases

1. **Accidental Modification of Existing MIT Text:**
   - *Risk:* Tooling or formatting errors could overwrite existing QuarkPan / MIT notices.
   - *Mitigation:* Explicit test assertion in `ThirdPartyNoticesTests` ensuring original 30 lines remain byte-for-byte identical.
2. **Code Signing on tvOS Hardware:**
   - *Risk:* Recipients replacing the framework cannot deploy to physical Apple TV without codesigning.
   - *Mitigation:* Document explicitly that simulator runs do not require code signing identities, but physical Apple TV deployment requires signing with the recipient's Apple Development team.

---

## 5. Verification Commands

1. **Notice Content & Preservation Tests:**
   ```bash
   xcodebuild test -scheme QuarkTheater -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:QuarkTheaterTests/ThirdPartyNoticesTests
   ```
2. **Project Generation Integrity Check:**
   ```bash
   python3 scripts/generate_xcode_project.py --check
   ```
3. **Verify Git Diff (Preservation Check):**
   ```bash
   git diff THIRD_PARTY_NOTICES.md
   ```
   (Must show only additions at the bottom of the file, zero deletions).
