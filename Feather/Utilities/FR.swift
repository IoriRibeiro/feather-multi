//
//  FR.swift
//  Feather
//
//  Created by samara on 22.04.2025.
//

import Foundation.NSURL
import UIKit.UIImage
import ZsignC
import NimbleJSON
import AltSourceKit
import IDeviceSwift
import CoreData

enum FR {
	static func handlePackageFile(
		_ ipa: URL,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = AppFileHandler(
				file: ipa,
				download: download,
				sourceProvenance: sourceProvenance
			)
			
			do {
				try await handler.copy()
				try await handler.extract()
				try await handler.move()
				try await handler.addToDatabase()
				try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func signPackageFile(
		_ app: AppInfoPresentable,
		using options: Options,
		icon: UIImage?,
		certificate: CertificatePair?,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = SigningHandler(app: app, options: options)
			handler.appCertificate = certificate
			handler.appIcon = icon
			
			do {
				try await handler.copy()
				try await handler.modify()
				try? await handler.clean()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				try? await handler.clean()
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func handleCertificateFiles(
		p12URL: URL,
		provisionURL: URL,
		p12Password: String,
		certificateName: String = "",
		isDefault: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		Task.detached {
			let handler = CertificateFileHandler(
				key: p12URL,
				provision: provisionURL,
				password: p12Password,
				nickname: certificateName.isEmpty ? nil : certificateName,
				isDefault: isDefault
			)
			
			do {
				try await handler.copy()
				try await handler.addToDatabase()
				await MainActor.run {
					completion(nil)
				}
			} catch {
				await MainActor.run {
					completion(error)
				}
			}
		}
	}
	
	static func checkPasswordForCertificate(
		for key: URL,
		with password: String,
		using provision: URL
	) -> Bool {
		defer {
			password_check_fix_free(provision.path)
		}
		
		password_check_fix(provision.path)
		
		if (!p12_password_check(key.path, password)) {
			return false
		}
		
		return true
	}
	
	static func movePairing(_ url: URL) {
		let fileManager = FileManager.default
		let dest = URL.documentsDirectory.appendingPathComponent("pairingFile.plist")
		
		try? fileManager.removeFileIfNeeded(at: dest)
		
		try? fileManager.copyItem(at: url, to: dest)
		
		HeartbeatManager.shared.start(true)
	}
	
	static func downloadSSLCertificates(
		from urlString: String,
		completion: @escaping (Bool) -> Void
	) {
		let generator = UINotificationFeedbackGenerator()
		generator.prepare()
		
		NBFetchService().fetch(from: urlString) { (result: Result<ServerView.ServerPackModel, Error>) in
			switch result {
			case .success(let pack):
				do {
					try FileManager.forceWrite(content: pack.key, to: "server.pem")
					try FileManager.forceWrite(content: pack.cert, to: "server.crt")
					try FileManager.forceWrite(content: pack.info.domains.commonName, to: "commonName.txt")
					generator.notificationOccurred(.success)
					completion(true)
				} catch {
					completion(false)
				}
			case .failure(_):
				completion(false)
			}
		}
	}
	
	static func handleSource(
		_ urlString: String,
		competion: @escaping () -> Void
	) {
		guard let url = URL(string: urlString) else { return }
		
		NBFetchService().fetch<ASRepository>(from: url) { (result: Result<ASRepository, Error>) in
			switch result {
			case .success(let data):
				let id = data.id ?? url.absoluteString
				
				if !Storage.shared.sourceExists(id) {
					Storage.shared.addSource(url, repository: data, id: id) { _ in
						competion()
					}
				} else {
					DispatchQueue.main.async {
						UIAlertController.showAlertWithOk(title: .localized("Error"), message: .localized("Repository already added."))
					}
				}
			case .failure(let error):
				DispatchQueue.main.async {
					UIAlertController.showAlertWithOk(title: .localized("Error"), message: error.localizedDescription)
				}
			}
		}
	}
	
	static func exportCertificateAndOpenUrl(using template: String) {
		// Helper that performs the export for a given certificate
		func performExport(for certificate: CertificatePair) {
			guard
				let certificateKeyFile = Storage.shared.getFile(.certificate, from: certificate),
				let certificateKeyFileData = try? Data(contentsOf: certificateKeyFile)
			else {
				return
			}
			
			let base64encodedCert = certificateKeyFileData.base64EncodedString()
			
			var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
			allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
			
			guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
				return
			}
			
			let urlStr = template
				.replacingOccurrences(of: "$(BASE64_CERT)", with: encodedCert)
				.replacingOccurrences(of: "$(PASSWORD)", with: certificate.password ?? "")
			
			guard let callbackUrl = URL(string: urlStr) else {
				return
			}
			
			UIApplication.shared.open(callbackUrl)
		}
		
		let certificates = Storage.shared.getAllCertificates()
		guard !certificates.isEmpty else { return }
		
		DispatchQueue.main.async {
			var selectionActions: [UIAlertAction] = []
			
			for cert in certificates {
				var title: String
				let decoded = Storage.shared.getProvisionFileDecoded(for: cert)
				
				title = cert.nickname ?? decoded?.Name ?? .localized("Unknown")
				
				if let getTaskAllow = decoded?.Entitlements?["get-task-allow"]?.value as? Bool, getTaskAllow == true {
					title = "🐞 \(title)"
				}
				
				let selectAction = UIAlertAction(title: title, style: .default) { _ in
					performExport(for: cert)
				}
				selectionActions.append(selectAction)
			}
			
			UIAlertController.showAlertWithCancel(
				title: .localized("Export Certificate"),
				message: .localized("Do you want to export your certificate to an external app? That app will be able to sign apps using your certificate."),
				style: .alert,
				actions: selectionActions
			)
		}
	}
}

// MARK: - Multi Open

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
		uniqueKeychain: Bool = false,
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

			// Without this every copy is signed with the exact same entitlements from the
			// provisioning profile, so all copies (and their extensions) share one keychain
			// and overwrite each other's keys.
			if
				uniqueKeychain,
				baseOptions.appEntitlementsFile == nil,
				let id = options.appIdentifier,
				let file = keychainEntitlementsFile(for: id, certificate: certificate)
			{
				options.appEntitlementsFile = file
			}

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

	/// Writes the certificate's entitlements with a keychain group unique to `identifier`
	/// (`TEAMID.identifier`). The first keychain group is the app's default one, so each copy
	/// gets its own keychain. Allowed because the profile grants `TEAMID.*`.
	@MainActor
	static func keychainEntitlementsFile(for identifier: String, certificate: CertificatePair?) -> URL? {
		guard
			let certificate,
			let profile = CertificateReader(Storage.shared.getFile(.provision, from: certificate)).decoded,
			let team = profile.TeamIdentifier.first
		else {
			return nil
		}

		var entitlements: [String: Any] = (profile.Entitlements ?? [:]).mapValues { $0.value }

		let existing = entitlements["keychain-access-groups"] as? [String] ?? []
		guard existing.contains("\(team).*") else {
			// profile doesn't allow arbitrary keychain groups, keep it as is
			return nil
		}

		var groups = ["\(team).\(identifier)"]
		if existing.contains("com.apple.token") {
			groups.append("com.apple.token")
		}
		entitlements["keychain-access-groups"] = groups

		guard let data = try? PropertyListSerialization.data(
			fromPropertyList: entitlements,
			format: .xml,
			options: 0
		) else {
			return nil
		}

		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("multiopen-\(identifier)-\(UUID().uuidString)")
			.appendingPathExtension("plist")

		do {
			try data.write(to: url, options: .atomic)
			return url
		} catch {
			return nil
		}
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
