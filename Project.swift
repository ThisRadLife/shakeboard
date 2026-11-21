import ProjectDescription

// ShakeBoard -- local macOS drag-shelf (Yoink replacement). A non-sandboxed agent app (no Dock or menu-bar icon) plus a
// sandboxed Share Extension that funnels shared content (files, images, web links, selected text)
// onto the shelf. Swift 5 language mode for the T1 spike; the real app can move to Swift 6.
// Tuist emits a per-TARGET default CODE_SIGN_IDENTITY ("-", ad-hoc) that overrides the project-level
// value, so a plain Release `xcodebuild` silently produced an ad-hoc build. Pin Developer ID on the
// shipping targets for RELEASE only; Debug stays ad-hoc so a clean clone without the certificate can
// build and run the tests. CI overrides both with CODE_SIGNING_ALLOWED=NO on the command line.
let developerIDSigning: Settings = .settings(configurations: [
    .debug(name: .debug, settings: ["CODE_SIGN_IDENTITY": "-"]),
    .release(name: .release, settings: [
        "CODE_SIGN_IDENTITY": "Developer ID Application",
        // Xcode's injected base entitlements include get-task-allow, which notarization rejects.
        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
        // Notarization needs a secure timestamp.
        "OTHER_CODE_SIGN_FLAGS": "--timestamp",
    ]),
])
// The test bundle is hosted by the Debug app, so it signs ad-hoc to match (library validation).
let adHocSigning: Settings = .settings(base: ["CODE_SIGN_IDENTITY": "-"])

// Sparkle's real public key is set here, and the Release build phase below still protects against an
// empty or placeholder value.
let appSigning: Settings = .settings(
    base: ["SPARKLE_PUBLIC_ED_KEY": "+Kw3+JSnalW89Z/W/8s+iIskJ3mOqSH7vTFdNXo3620="],
    configurations: [
        .debug(name: .debug, settings: ["CODE_SIGN_IDENTITY": "-"]),
        .release(name: .release, settings: [
            "CODE_SIGN_IDENTITY": "Developer ID Application",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            "OTHER_CODE_SIGN_FLAGS": "--timestamp",
        ]),
    ]
)

let project = Project(
    name: "ShakeBoard",
    packages: [
        // Sparkle 2.10.1 at an immutable revision. A mutable version tag is not a sufficient release supply-chain pin.
        .remote(
            url: "https://github.com/sparkle-project/Sparkle",
            requirement: .revision("ab7d71291238df6e0492143b120c9b696a35f603")
        ),
    ],
    settings: .settings(base: [
        "SWIFT_VERSION": "5.0",
        "MACOSX_DEPLOYMENT_TARGET": "14.0",
        "MARKETING_VERSION": "0.9.0",
        "CURRENT_PROJECT_VERSION": "1",
        // Developer ID signing for a notarizable release (was ad-hoc "-"). Both the app and the
        // sandboxed Share Extension sign with this identity + hardened runtime, which notarization
        // requires and which finally makes the extension's Photos share sandbox-token honored.
        "CODE_SIGN_STYLE": "Manual",
        "DEVELOPMENT_TEAM": "DQ9FW5YXUQ",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        // The "Embed shakeboard-mcp" phase copies the helper product into the app bundle.
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    ]),
    targets: [
        .target(
            name: "ShakeBoard",
            destinations: .macOS,
            product: .app,
            bundleId: "com.thisradlife.shakeboard",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSUIElement": true,                 // agent: no Dock icon (and no menu-bar icon since v2)
                "CFBundleDisplayName": "ShakeBoard",
                "SUFeedURL": "https://thisradlife.github.io/shakeboard/appcast.xml",
                "SUPublicEDKey": "$(SPARKLE_PUBLIC_ED_KEY)",
                "SUEnableSystemProfiling": false,
                // The Share Extension hands content back via shakeboard://add?dir=<handoff folder>.
                "CFBundleURLTypes": [
                    [
                        "CFBundleURLName": "com.thisradlife.shakeboard",
                        "CFBundleURLSchemes": ["shakeboard"],
                    ],
                ],
            ]),
            sources: ["Sources/ShakeBoard/**", "Sources/Shared/**"],
            resources: [
                "Sources/ShakeBoard/Assets.xcassets",
                "Sources/ShakeBoard/AppIcon.icon",
            ],
            scripts: [
                .post(script: """
                    set -euo pipefail
                    if [[ "${CONFIGURATION}" != "Release" || "${CODE_SIGNING_ALLOWED:-YES}" == "NO" || "${SHAKEBOARD_ALLOW_UNSET_SPARKLE_KEY:-0}" == "1" ]]; then
                      exit 0
                    fi
                    INFO_PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
                    KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${INFO_PLIST}" 2>/dev/null || true)"
                    if [[ -z "${KEY}" || "${KEY}" == "UNSET_SPARKLE_PUBLIC_ED_KEY" ]]; then
                      echo "error: ShakeBoard Release requires a real SUPublicEDKey. Set SPARKLE_PUBLIC_ED_KEY, or set SHAKEBOARD_ALLOW_UNSET_SPARKLE_KEY=1 only for a local non-shipping Release build." >&2
                      exit 1
                    fi
                    """,
                      name: "Require Sparkle public key for Release",
                      basedOnDependencyAnalysis: false),
                // shakeboard-mcp (the MCP stdio helper) ships inside the app at Contents/MacOS/shakeboard-mcp, already
                // signed by its own target (same identity + hardened runtime); the app's signature then seals it.
                .post(script: """
                    set -e
                    cp -f "${BUILT_PRODUCTS_DIR}/shakeboard-mcp" "${TARGET_BUILD_DIR}/${EXECUTABLE_FOLDER_PATH}/shakeboard-mcp"
                    """,
                      name: "Embed shakeboard-mcp",
                      inputPaths: ["$(BUILT_PRODUCTS_DIR)/shakeboard-mcp"],
                      outputPaths: ["$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/shakeboard-mcp"],
                      basedOnDependencyAnalysis: true),
                // Sparkle ships its nested code ad-hoc signed. Re-sign it after Embed Frameworks and before
                // Xcode seals the app so the Developer ID artifact can pass notarization and Gatekeeper.
                .post(script: """
                    set -euo pipefail

                    mark_complete() {
                      mkdir -p "$(dirname "${SCRIPT_OUTPUT_FILE_0}")"
                      touch "${SCRIPT_OUTPUT_FILE_0}"
                    }

                    if [[ "${CONFIGURATION}" != "Release" \
                      || "${CODE_SIGNING_ALLOWED:-YES}" == "NO" \
                      || -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" \
                      || "${EXPANDED_CODE_SIGN_IDENTITY}" == "-" ]]; then
                      mark_complete
                      exit 0
                    fi

                    SPARKLE_FRAMEWORK="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
                    SPARKLE_VERSION="${SPARKLE_FRAMEWORK}/Versions/B"
                    if [[ ! -d "${SPARKLE_VERSION}" ]]; then
                      echo "error: Missing embedded Sparkle framework at ${SPARKLE_VERSION}" >&2
                      exit 1
                    fi

                    # ShakeBoard is not sandboxed and does not enable Sparkle's installer-launcher or
                    # downloader services, so Sparkle documents these XPC services as removable.
                    rm -rf "${SPARKLE_VERSION}/XPCServices"
                    if [[ -L "${SPARKLE_FRAMEWORK}/XPCServices" ]]; then
                      rm -f "${SPARKLE_FRAMEWORK}/XPCServices"
                    fi

                    CODESIGN_FLAGS=(
                      --force
                      --sign "${EXPANDED_CODE_SIGN_IDENTITY}"
                      --options runtime
                      --timestamp
                    )
                    if [[ -n "${OTHER_CODE_SIGN_FLAGS:-}" ]]; then
                      IFS=' ' read -r -a OTHER_FLAGS <<< "${OTHER_CODE_SIGN_FLAGS}"
                      for FLAG in "${OTHER_FLAGS[@]}"; do
                        # A secure timestamp is mandatory above; do not pass the common setting twice.
                        if [[ "${FLAG}" != "--timestamp" ]]; then
                          CODESIGN_FLAGS+=("${FLAG}")
                        fi
                      done
                    fi

                    ENTITLEMENTS_FILE="$(mktemp "${DERIVED_FILE_DIR}/sparkle-entitlements.XXXXXX")"
                    trap 'rm -f "${ENTITLEMENTS_FILE}"' EXIT
                    sign_sparkle_code() {
                      local SIGN_PATH="$1"
                      if codesign -d --entitlements :- "${SIGN_PATH}" > "${ENTITLEMENTS_FILE}" 2>/dev/null \
                        && grep -q '<key>' "${ENTITLEMENTS_FILE}"; then
                        codesign "${CODESIGN_FLAGS[@]}" --preserve-metadata=entitlements "${SIGN_PATH}"
                      else
                        codesign "${CODESIGN_FLAGS[@]}" "${SIGN_PATH}"
                      fi
                    }

                    sign_sparkle_code "${SPARKLE_VERSION}/Autoupdate"
                    sign_sparkle_code "${SPARKLE_VERSION}/Updater.app"
                    sign_sparkle_code "${SPARKLE_VERSION}"
                    mark_complete
                    """,
                      name: "Re-sign embedded Sparkle for Release",
                      inputPaths: [
                        "$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/Sparkle.framework/Versions/B/Autoupdate",
                        "$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/Sparkle.framework/Versions/B/Updater.app",
                        "$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/Sparkle.framework/Versions/B",
                      ],
                      outputPaths: ["$(DERIVED_FILE_DIR)/shakeboard-sparkle-resigned"],
                      basedOnDependencyAnalysis: false),
            ],
            dependencies: [
                .target(name: "ShakeBoardShare"),
                .target(name: "ShakeBoardMCP"),
                .package(product: "Sparkle"),
            ],
            settings: appSigning
            // No entitlements -> non-sandboxed (needed for the global drag monitor + reading the
            // extension's handoff folder).
        ),
        .target(
            name: "ShakeBoardShare",
            destinations: .macOS,
            product: .appExtension,
            bundleId: "com.thisradlife.shakeboard.share",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "CFBundleDisplayName": "ShakeBoard",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsFileWithMaxCount": 20,
                            "NSExtensionActivationSupportsImageWithMaxCount": 20,
                            "NSExtensionActivationSupportsWebURLWithMaxCount": 10,
                            "NSExtensionActivationSupportsText": true,
                        ],
                    ],
                ],
            ]),
            sources: ["Sources/ShakeBoardShare/**"],
            entitlements: "Sources/ShakeBoardShare/ShakeBoardShare.entitlements",
            settings: developerIDSigning
        ),
        // The MCP stdio helper Claude Code / Codex launch. A dumb pipe to the running app over its owner-only
        // Unix socket (see Sources/Shared/MCPCore.swift); embedded into ShakeBoard.app by the script above.
        .target(
            name: "ShakeBoardMCP",
            destinations: .macOS,
            product: .commandLineTool,
            productName: "shakeboard-mcp",
            bundleId: "com.thisradlife.shakeboard.mcp",
            deploymentTargets: .macOS("14.0"),
            sources: ["Sources/ShakeBoardMCP/**", "Sources/Shared/**"],
            settings: developerIDSigning
        ),
        // Lean XCTest target -- @testable import ShakeBoard, hosted by the ShakeBoard app so the app module is
        // testable; no separate core framework. A unit-test target can't depend on an app extension,
        // so the one ShareViewController source is compiled straight into the test bundle to reach the
        // filename sanitizer -- same source, real logic. (P1-2)
        .target(
            name: "ShakeBoardTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.thisradlife.shakeboard.tests",
            deploymentTargets: .macOS("14.0"),
            infoPlist: .default,
            sources: ["Tests/ShakeBoardTests/**", "Sources/ShakeBoardShare/ShareViewController.swift"],
            dependencies: [.target(name: "ShakeBoard")],
            settings: adHocSigning
        ),
    ],
    schemes: [
        .scheme(
            name: "ShakeBoard",
            shared: true,
            buildAction: .buildAction(targets: ["ShakeBoardMCP", "ShakeBoard"]),
            runAction: .runAction(configuration: .debug, executable: .target("ShakeBoard"))
        ),
        .scheme(
            name: "ShakeBoardTests",
            shared: true,
            buildAction: .buildAction(targets: ["ShakeBoard", "ShakeBoardTests"]),
            testAction: .targets(["ShakeBoardTests"])
        ),
    ]
)
