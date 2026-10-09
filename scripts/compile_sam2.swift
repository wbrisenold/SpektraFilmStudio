import Foundation
import CoreML
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for package in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where package.pathExtension == "mlpackage" {
    let final = output.appendingPathComponent(package.deletingPathExtension().lastPathComponent + ".mlmodelc")
    if FileManager.default.fileExists(atPath: final.path) { continue }
    let compiled = try MLModel.compileModel(at: package)
    defer { try? FileManager.default.removeItem(at: compiled) }
    try FileManager.default.moveItem(at: compiled, to: final)
    print("Compiled \(package.lastPathComponent)")
}
