// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "QuotedKit",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        // Pure models and logic shared by the app and the widget extension. No Supabase, no UIKit.
        .library(name: "QuotedCore", targets: ["QuotedCore"]),
        // Supabase-backed repositories used by the app target only.
        .library(name: "QuotedKit", targets: ["QuotedKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.55.4"),
    ],
    targets: [
        .target(
            name: "QuotedCore"
        ),
        .target(
            name: "QuotedKit",
            dependencies: [
                "QuotedCore",
                .product(name: "Supabase", package: "supabase-swift"),
            ]
        ),
        .testTarget(
            name: "QuotedCoreTests",
            dependencies: ["QuotedCore"]
        ),
        .testTarget(
            name: "QuotedKitTests",
            dependencies: ["QuotedKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
