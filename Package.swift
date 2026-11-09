// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FTPServer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FTPServer", targets: ["FTPServer"])
    ],
    targets: [
        .executableTarget(
            name: "FTPServer",
            path: "Sources/FTPServer",
            swiftSettings: [
                // GUI 可执行目标必须声明为库解析方式，否则 @main 与顶层代码规则冲突
                .unsafeFlags(["-parse-as-library"])
            ]
        )
    ]
)
