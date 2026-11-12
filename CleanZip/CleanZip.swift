import Cocoa
import Foundation
import ZIPFoundation

@main enum CleanZipApp {

  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }

}

final class AppDelegate: NSObject, NSApplicationDelegate {

  private var didReceiveFiles = false

  // 複数回に分かれて届くファイルを保持
  private var pendingURLs: [URL] = []
  private var processingWorkItem: DispatchWorkItem?

  let fileManager = FileManager.default

  func applicationDidFinishLaunching(_ notification: Notification) {

    // アプリをダブルクリックした場合は終了
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      if !self.didReceiveFiles {
        NSApp.terminate(nil)
      }
    }

  }

  func application(
    _ sender: NSApplication,
    openFiles filenames: [String]
  ) {

    didReceiveFiles = true

    let urls = filenames.map { filename in
      return URL(fileURLWithPath: filename)
    }

    // ファイル通知をまとめて受け取る
    pendingURLs.append(contentsOf: urls)
    processingWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in

      guard let self = self else {
        return
      }

      // 重複を除去して受信順を維持
      var seen = Set<URL>()

      let urls = self.pendingURLs.filter { url in
        return seen.insert(url.standardizedFileURL).inserted
      }

      self.pendingURLs.removeAll()
      self.processingWorkItem = nil

      // 圧縮か解凍かを分岐
      if urls.count == 1, let url = urls.first, self.isZipfile(url: url) {
        self.unzip(url: url)
      } else {
        self.zipFiles(urls: urls)
      }

    }

    processingWorkItem = workItem

    // 追加のファイル通知を0.5秒待つ
    DispatchQueue.main.asyncAfter(
      deadline: .now() + 0.5,
      execute: workItem
    )

    sender.reply(toOpenOrPrint: .success)

  }

  // ZIPかどうか判定
  private func isZipfile(url: URL) -> Bool {

    // 読み込み専用で開く
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return false
    }

    // スコープを抜ける直前に処理を実行
    defer {
      try? handle.close()
    }

    let result: Data?

    do {
      result = try handle.read(upToCount: 4)
    } catch {
      result = nil
    }

    guard let header = result, header.count >= 4 else {
      return false
    }

    // ZIPファイルの代表的な先頭シグネチャ: PK 03 04
    return header[0] == 0x50 && header[1] == 0x4B && header[2] == 0x03
      && header[3] == 0x04

  }

  private func zipFiles(urls: [URL]) {

    guard !urls.isEmpty else {
      showAlert(message: "圧縮する項目がありません。")
      return
    }

    // 作成途中のZIPだけを削除する
    var createdArchiveURL: URL?
    var completed = false

    defer {
      if !completed, let url = createdArchiveURL {
        try? fileManager.removeItem(at: url)
      }
    }

    do {

      // 最初の項目の親フォルダを基準にする
      let baseURL = urls[0].deletingLastPathComponent()

      let isMultiple = urls.count > 1
      let archiveName: String

      if isMultiple {
        archiveName = "Archive.zip"
      } else {
        archiveName =
          urls[0].deletingPathExtension().lastPathComponent + ".zip"
      }

      let destinationURL = baseURL.appendingPathComponent(archiveName)

      if fileManager.fileExists(atPath: destinationURL.path) {
        print(destinationURL.path)
        showAlert(message: "\(archiveName)がすでに存在するので圧縮できませんでした。")
        return
      }

      // 出力先自身を圧縮対象から除外
      var sourceURLs: [URL] = []

      for url in urls {
        if url.standardizedFileURL != destinationURL.standardizedFileURL {
          sourceURLs.append(url)
        }
      }

      guard !sourceURLs.isEmpty else {
        showAlert(message: "圧縮する項目がありません。")
        return
      }

      // すでにファイル・フォルダがあれば処理停止
      if fileManager.fileExists(atPath: destinationURL.path) {
        return
      }

      let archive = try Archive(url: destinationURL, accessMode: .create)

      // 作成したZIPを記録
      createdArchiveURL = destinationURL

      // 複数選択時はZIP内にArchiveフォルダを作成
      if isMultiple {
        try archive.addEntry(
          with: "Archive/",
          type: .directory,
          uncompressedSize: 0,
          compressionMethod: .deflate,
          bufferSize: defaultWriteChunkSize,
          provider: { (_: Int64, _: Int) -> Data in
            return Data()
          }
        )
      }

      for sourceURL in sourceURLs {

        // 各項目の親フォルダから相対パスを取得
        let sourceBaseURL = sourceURL.deletingLastPathComponent()

        try addToArchive(
          sourceURL: sourceURL,
          archive: archive,
          baseURL: sourceBaseURL,
          prefix: isMultiple ? "Archive/" : ""
        )

      }

      completed = true
      NSApp.terminate(nil)

    } catch {
      print(error.localizedDescription)
      showAlert(message: "圧縮できませんでした。")
    }

  }

  private func addToArchive(
    sourceURL: URL,
    archive: Archive,
    baseURL: URL,
    prefix: String = ""
  ) throws {

    let name = sourceURL.lastPathComponent

    let excludedNames: Set<String> = [
      ".DS_Store",
      "__MACOSX",
      ".AppleDouble",
      ".Spotlight-V100",
      ".Trashes",
      ".fseventsd",
      ".TemporaryItems",
      ".LSOverride",
      ".apdisk",
    ]

    // 不要なファイル・フォルダを除外
    if excludedNames.contains(name) || name.hasPrefix("._") {
      return
    }

    let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])

    // ZIP内の親フォルダを付加
    let path = prefix + relativePath(of: sourceURL, from: baseURL)

    if values.isDirectory == true {

      // フォルダ自体を追加（空のフォルダも維持）
      try archive.addEntry(
        with: path + "/",
        type: .directory,
        uncompressedSize: 0,
        compressionMethod: .deflate,
        bufferSize: defaultWriteChunkSize,
        provider: { (_: Int64, _: Int) -> Data in
          return Data()
        }
      )

      let children = try fileManager.contentsOfDirectory(
        at: sourceURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
      )

      for childURL in children {
        try addToArchive(
          sourceURL: childURL,
          archive: archive,
          baseURL: baseURL,
          prefix: prefix
        )
      }

    } else {

      // 追加して圧縮
      try archive.addEntry(
        with: path,
        fileURL: sourceURL,
        compressionMethod: .deflate
      )

    }

  }

  private func relativePath(of url: URL, from baseURL: URL) -> String {

    let basePath = baseURL.standardizedFileURL.path
    let fullPath = url.standardizedFileURL.path

    return String(fullPath.dropFirst(basePath.count + 1))

  }

  // 解凍
  private func unzip(url: URL) {

    do {

      // zipファイルがあるディレクトリを指定
      let destinationURL = url.deletingLastPathComponent()

      // ZIP内の項目を確認
      let archive = try Archive(url: url, accessMode: .read)

      if Array(archive).count == 0 {
        showAlert(
          message:
            "解凍できませんでした。\n\nパスワード付きのZIPファイルなど、対応していない形式かもしれません。"
        )
        return
      }

      for entry in archive {

        let outputURL = destinationURL.appendingPathComponent(
          entry.path
        )

        if fileManager.fileExists(atPath: outputURL.path) {
          print(outputURL)
          showAlert(message: "ファイル・フォルダがすでに存在するので解凍できませんでした。")
          return
        }

      }

      try fileManager.unzipItem(at: url, to: destinationURL)

      NSApp.terminate(nil)

    } catch {
      print(error.localizedDescription)
      showAlert(message: "解凍できませんでした。")
    }

  }

  // アラートで出力
  private func showAlert(message: String) {

    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()

    NSApp.terminate(nil)

  }

}
