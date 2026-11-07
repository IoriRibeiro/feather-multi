//
//  MultiOpen.swift
//  Feather
//
//  "Multi Open": signs N copies of the same app, each one with its own
//  bundle identifier (base.1, base.2, ...) and name ("WhatsApp 1", ...),
//  then installs them one after another.
//
//  Re-running it with the same start/count reuses the same identifiers,
//  so iOS updates the installed copies in place and keeps their data.
//

import Foundation
import CoreData
import UIKit

enum MultiOpen {
	/// Notification posted after a batch is signed. `userInfo["identifiers"]` is `[String]`.
	static let installNotification = Notification.Name("Feather.installMultipleApps")

	static func identifier(base: String, index: Int) -> String {
		"\(base).\(index)"
	}

	static func name(base: String, index: Int) -> String {
		"\(base) \(index)"
	}

	/// Removes previously signed copies that use the given identifiers,
	/// so updating a batch doesn't pile up old copies in storage.
	@MainActor
	static func removeSignedCopies(with identifiers: [String]) {
		let request: NSFetchRequest<Signed> = Signed.fetchRequest()
		request.predicate = NSPredicate(format: "identifier IN %@", identifiers)

		guard let results = try? Storage.shared.context.fetch(request) else { return }

		for app in results {
			Storage.shared.deleteApp(for: app)
		}
	}

	/// Signs `count` copies starting at `start`. Runs sequentially to keep memory/disk usage sane.
	@MainActor
	static func signCopies(
		of app: AppInfoPresentable,
		using baseOptions: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		start: Int,
		count: Int,
		progress: @escaping (Int) -> Void
	) async -> (identifiers: [String], failures: [String]) {
		let baseIdentifier = baseOptions.appIdentifier ?? app.identifier ?? "app"
		let baseName = baseOptions.appName ?? app.name ?? "App"

		var signed: [String] = []
		var failures: [String] = []

		for offset in 0..<count {
			let index = start + offset
			progress(offset + 1)

			var options = baseOptions
			options.appIdentifier = identifier(base: baseIdentifier, index: index)
			options.appName = name(base: baseName, index: index)
			// never delete the source app or auto-install in the middle of a batch
			options.post_deleteAppAfterSigned = false
			options.post_installAppAfterSigned = false

			let error: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
				FR.signPackageFile(
					app,
					using: options,
					icon: icon,
					certificate: certificate
				) { error in
					continuation.resume(returning: error)
				}
			}

			if let error {
				failures.append("\(options.appName ?? "\(index)"): \(error.localizedDescription)")
			} else if let id = options.appIdentifier {
				signed.append(id)
			}
		}

		return (signed, failures)
	}
}

/// Holds the list of apps waiting to be installed in sequence.
final class MultiInstallQueue: ObservableObject {
	static let shared = MultiInstallQueue()

	/// Signed app UUIDs still waiting to be installed.
	@Published var pending: [String] = []
	/// Total in the current batch (for the "3 of 15" label).
	@Published var total: Int = 0

	var isActive: Bool { total > 0 }

	/// 1-based position of the app currently being installed.
	var currentPosition: Int { max(total - pending.count, 1) }

	func reset() {
		pending.removeAll()
		total = 0
	}
}
