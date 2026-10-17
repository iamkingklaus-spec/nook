import UIKit
import UniformTypeIdentifiers

/// URL handoff only. No page fetching, parser or Gemini work in this process.
@MainActor
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private var sharedURL: URL?
    private var providers: [NSItemProvider] = []
    private var timeout: Task<Void, Never>?
    private var resolved = false
    private var didStart = false
    private var wasEnqueued = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let titleLabel = UILabel()
        titleLabel.text = "Nookie"
        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.adjustsFontForContentSizeCategory = true
        statusLabel.text = "正在读取文章链接…"
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        actionButton.setTitle("复制链接并返回", for: .normal)
        actionButton.isEnabled = false
        actionButton.addAction(UIAction { [weak self] _ in self?.finishAction() }, for: .touchUpInside)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addAction(UIAction { [weak self] _ in self?.finish() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, actionButton, cancelButton])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }; didStart = true
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        providers = items.flatMap { $0.attachments ?? [] }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, !self.resolved else { return }
            self.resolved = true
            self.statusLabel.text = "读取分享内容超时。请取消后重试，或复制网页链接到 Nookie。"
        }
        load(index: 0)
    }

    private func load(index: Int) {
        guard !resolved else { return }
        guard index < providers.count else {
            resolved = true; timeout?.cancel()
            statusLabel.text = "未找到有效的 http / https 文章链接。此入口暂不支持图片、PDF 或视频文件。"
            return
        }
        let provider = providers[index]
        let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            ? UTType.url.identifier : UTType.plainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else { load(index: index + 1); return }
        provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] item, _ in
            // Only immutable text crosses back to the main actor.
            let text = (item as? URL)?.absoluteString ?? (item as? String)
            Task { @MainActor [weak self] in
                guard let self, !self.resolved else { return }
                if let text, let url = try? SharedArticleURL.fromSharedText(text) { self.received(url) }
                else { self.load(index: index + 1) }
            }
        }
    }

    private func received(_ url: URL) {
        resolved = true; timeout?.cancel(); sharedURL = url
        let inbox = SharedArticleInbox.configured()
        if inbox.directory != nil {
            do {
                try inbox.enqueue(SharedArticleEnvelope(url: url))
                wasEnqueued = true
                statusLabel.text = "已添加到 Nookie 的待导入队列。打开 Nookie 后会保存文章；网络和正文处理在主 App 中完成。"
                actionButton.setTitle("完成", for: .normal)
            } catch {
                statusLabel.text = "分享队列写入失败，尚未导入。可以复制链接，再到 Nookie → 打开网页链接中粘贴。"
            }
        } else {
            statusLabel.text = "当前安装不支持直接共享保存，尚未导入。请点击下方复制，然后打开 Nookie → Saved / 收藏 → 打开网页链接，粘贴并打开。"
        }
        actionButton.isEnabled = true
    }

    private func finishAction() {
        if !wasEnqueued, let sharedURL {
            UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: sharedURL.absoluteString]],
                options: [.localOnly: true])
        }
        finish()
    }
    private func finish() {
        resolved = true; timeout?.cancel()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
