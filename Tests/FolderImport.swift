import Foundation
@main struct FolderTest {
static func main() throws {
 let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root.appendingPathComponent("nested"),withIntermediateDirectories:true)
 for name in ["10.png","2.jpg",".hidden.png","notes.txt","nested/1.PNG"] {try Data().write(to:root.appendingPathComponent(name))}
 let files=expandImageInputs([root,root.appendingPathComponent("2.jpg")])
 precondition(files.count==3)
 precondition(files.map(\.lastPathComponent)==["2.jpg","10.png","1.PNG"])
 precondition(expandImageInputs([root.appendingPathComponent("notes.txt")]).isEmpty)
 print("PASS: recursive folder import; natural order; hidden/non-image exclusion; deduplication")
}
}
