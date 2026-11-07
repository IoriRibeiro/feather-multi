//
//  SigningView.swift
//  Feather
//
//  Created by samara on 14.04.2025.
//

import SwiftUI
import PhotosUI
import NimbleViews

// MARK: - View
struct SigningView: View {
	@Environment(\.dismiss) var dismiss
	@StateObject private var _optionsManager = OptionsManager.shared
	
	@State private var _temporaryOptions: Options = OptionsManager.shared.options
	@State private var _temporaryCertificate: Int
	@State private var _isAltPickerPresenting = false
	@State private var _isFilePickerPresenting = false
	@State private var _isImagePickerPresenting = false
	@State private var _isSigning = false
	@State private var _selectedPhoto: PhotosPickerItem? = nil
	@State var appIcon: UIImage?

	// MARK: Multi Open
	@AppStorage("Feather.multiOpen.enabled") private var _multiOpenEnabled = false
	@AppStorage("Feather.multiOpen.start") private var _multiOpenStart = 1
	@AppStorage("Feather.multiOpen.count") private var _multiOpenCount = 15
	@AppStorage("Feather.multiOpen.installAfter") private var _multiOpenInstallAfter = true
	@AppStorage("Feather.multiOpen.replaceOld") private var _multiOpenReplaceOld = true
	@State private var _multiOpenProgress = 0
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var certificates: FetchedResults<CertificatePair>
	
	private func _selectedCert() -> CertificatePair? {
		guard certificates.indices.contains(_temporaryCertificate) else { return nil }
		return certificates[_temporaryCertificate]
	}
	
	var app: AppInfoPresentable
	
	init(app: AppInfoPresentable) {
		self.app = app
		let storedCert = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		__temporaryCertificate = State(initialValue: storedCert)
	}
		
	// MARK: Body
	var body: some View {
		NBNavigationView("", displayMode: .inline) {
			Form {
				_customizationOptions(for: app)
				_multiOpen(for: app)
				_cert()
				_customizationProperties(for: app)
				
				// horrible
				Rectangle()
					.foregroundStyle(.clear)
					.frame(height: 30)
					.listRowBackground(EmptyView())
			}
			.overlay {
				VStack(spacing: 0) {
					Spacer()
					NBVariableBlurView()
						.frame(height: UIDevice.current.userInterfaceIdiom == .pad ? 60 : 80)
						.rotationEffect(.degrees(180))
						.overlay {
							Button {
								_start()
							} label: {
								NBSheetButton(title: _startButtonTitle, style: .prominent)
									.padding()
							}
							.buttonStyle(.plain)
							.offset(y: UIDevice.current.userInterfaceIdiom == .pad ? -20 : -40)
						}
				}
				.ignoresSafeArea(edges: .bottom)
			}

			.toolbar {
				NBToolbarButton(role: .dismiss)
				ToolbarItem(placement: .principal) {
					Image("Glyph")
						.resizable()
						.scaledToFit()
						.frame(height: 38)
				}
				NBToolbarButton(
					.localized("Reset"),
					style: .text,
					placement: .topBarTrailing
				) {
					_temporaryOptions = OptionsManager.shared.options
					appIcon = nil
				}
			}
			.sheet(isPresented: $_isAltPickerPresenting) { SigningAlternativeIconView(app: app, appIcon: $appIcon, isModifing: .constant(true)) }
			.sheet(isPresented: $_isFilePickerPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes:  [.image],
					onDocumentsPicked: { urls in
						guard let selectedFileURL = urls.first else { return }
						self.appIcon = UIImage.fromFile(selectedFileURL)?.resizeToSquare()
					}
				)
				.ignoresSafeArea()
			}
			.photosPicker(isPresented: $_isImagePickerPresenting, selection: $_selectedPhoto)
			.onChange(of: _selectedPhoto) { newValue in
				guard let newValue else { return }
				
				Task {
					if let data = try? await newValue.loadTransferable(type: Data.self),
					   let image = UIImage(data: data)?.resizeToSquare() {
						appIcon = image
					}
				}
			}
			.disabled(_isSigning)
			.animation(.smooth, value: _isSigning)
		}
		.onAppear {
			// ppq protection
			if
				_optionsManager.options.ppqProtection,
				let identifier = app.identifier,
				let cert = _selectedCert(),
				cert.ppQCheck
			{
				_temporaryOptions.appIdentifier = "\(identifier).\(_optionsManager.options.ppqString)"
			}
			
			if
				let currentBundleId = app.identifier,
				let newBundleId = _temporaryOptions.identifiers[currentBundleId]
			{
				_temporaryOptions.appIdentifier = newBundleId
			}
			
			if
				let currentName = app.name,
				let newName = _temporaryOptions.displayNames[currentName]
			{
				_temporaryOptions.appName = newName
			}
		}
	}
}

// MARK: - Extension: View
extension SigningView {
	@ViewBuilder
	private func _customizationOptions(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Customization")) {
			Menu {
				Button(.localized("Select Alternative Icon"), systemImage: "app.dashed") { _isAltPickerPresenting = true }
				Button(.localized("Choose from Files"), systemImage: "folder") { _isFilePickerPresenting = true }
				Button(.localized("Choose from Photos"), systemImage: "photo") { _isImagePickerPresenting = true }
			} label: {
				if let icon = appIcon {
					Image(uiImage: icon)
						.appIconStyle()
				} else {
					FRAppIconView(app: app, size: 56)
				}
			}
			
			_infoCell(.localized("Name"), desc: _temporaryOptions.appName ?? app.name) {
				SigningPropertiesView(
					title: .localized("Name"),
					initialValue: _temporaryOptions.appName ?? (app.name ?? ""),
					bindingValue: $_temporaryOptions.appName
				)
			}
			_infoCell(.localized("Identifier"), desc: _temporaryOptions.appIdentifier ?? app.identifier) {
				SigningPropertiesView(
					title: .localized("Identifier"),
					initialValue: _temporaryOptions.appIdentifier ?? (app.identifier ?? ""),
					bindingValue: $_temporaryOptions.appIdentifier
				)
			}
			_infoCell(.localized("Version"), desc: _temporaryOptions.appVersion ?? app.version) {
				SigningPropertiesView(
					title: .localized("Version"),
					initialValue: _temporaryOptions.appVersion ?? (app.version ?? ""),
					bindingValue: $_temporaryOptions.appVersion
				)
			}
		}
	}
	
	private var _startButtonTitle: String {
		guard _multiOpenEnabled else { return .localized("Start Signing") }
		if _isSigning {
			return "Assinando \(_multiOpenProgress) de \(_multiOpenCount)…"
		}
		return "Assinar \(_multiOpenCount) cópias"
	}

	@ViewBuilder
	private func _multiOpen(for app: AppInfoPresentable) -> some View {
		let baseIdentifier = _temporaryOptions.appIdentifier ?? app.identifier ?? "app"
		let baseName = _temporaryOptions.appName ?? app.name ?? "App"
		let last = _multiOpenStart + _multiOpenCount - 1

		Section {
			Toggle(isOn: $_multiOpenEnabled) {
				Label("App Multi Open", systemImage: "square.on.square")
			}

			if _multiOpenEnabled {
				Stepper(value: $_multiOpenStart, in: 1...999) {
					LabeledContent("Começar no", value: "\(_multiOpenStart)")
				}
				Stepper(value: $_multiOpenCount, in: 1...50) {
					LabeledContent("Duplicar", value: "\(_multiOpenCount)x")
				}
				Toggle("Instalar todos depois de assinar", isOn: $_multiOpenInstallAfter)
				Toggle("Substituir cópias antigas", isOn: $_multiOpenReplaceOld)
			}
		} footer: {
			if _multiOpenEnabled {
				Text("Vai criar \(MultiOpen.name(base: baseName, index: _multiOpenStart)) até \(MultiOpen.name(base: baseName, index: last)) (\(MultiOpen.identifier(base: baseIdentifier, index: _multiOpenStart)) … .\(last)). Para atualizar, assine a versão nova com os mesmos números: as cópias são atualizadas sem perder os dados.")
			}
		}
	}

	@ViewBuilder
	private func _cert() -> some View {
		NBSection(.localized("Signing")) {
			if let cert = _selectedCert() {
				NavigationLink {
					CertificatesView(selectedCert: $_temporaryCertificate)
				} label: {
					CertificatesCellView(
						cert: cert
					)
				}
			} else {
				Text(.localized("No Certificate"))
					.font(.footnote)
					.foregroundColor(.disabled())
			}
		}
	}
	
	@ViewBuilder
	private func _customizationProperties(for app: AppInfoPresentable) -> some View {
		NBSection(.localized("Advanced")) {
			DisclosureGroup(.localized("Modify")) {
				NavigationLink(.localized("Existing Dylibs")) {
					SigningDylibView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
				
				NavigationLink(.localized("Frameworks & PlugIns")) {
					SigningFrameworksView(
						app: app,
						options: $_temporaryOptions.optional()
					)
				}
			
				NavigationLink(.localized("Entitlements") + " (BETA)") {
					SigningEntitlementsView(
						bindingValue: $_temporaryOptions.appEntitlementsFile
					)
				}
				
				NavigationLink(.localized("Tweaks")) {
					SigningTweaksView(
						options: $_temporaryOptions
					)
				}
			}
			
			NavigationLink(.localized("Properties")) {
				Form { SigningOptionsView(
					options: $_temporaryOptions,
					temporaryOptions: _optionsManager.options
				)}
				.navigationTitle(.localized("Properties"))
			}
		}
	}
	
	@ViewBuilder
	private func _infoCell<V: View>(_ title: String, desc: String?, @ViewBuilder destination: () -> V) -> some View {
		NavigationLink {
			destination()
		} label: {
			LabeledContent(title) {
				Text(desc ?? .localized("Unknown"))
			}
		}
	}
}

// MARK: - Extension: View (import)
extension SigningView {
	private func _start() {
		guard
			_selectedCert() != nil || _temporaryOptions.signingOption != .default
		else {
			UIAlertController.showAlertWithOk(
				title: .localized("No Certificate"),
				message: .localized("Please go to settings and import a valid certificate"),
				isCancel: true
			)
			return
		}

		let generator = UIImpactFeedbackGenerator(style: .light)
		generator.impactOccurred()
		_isSigning = true

		if _multiOpenEnabled {
			_startMultiOpen()
			return
		}

		FR.signPackageFile(
			app,
			using: _temporaryOptions,
			icon: appIcon,
			certificate: _selectedCert()
		) { error in
			if let error {
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel) { _ in
					dismiss()
				}
				
				UIAlertController.showAlert(
					title: "Error",
					message: error.localizedDescription,
					actions: [ok]
				)
			} else {
				if
					_temporaryOptions.post_deleteAppAfterSigned,
					!app.isSigned
				{
					Storage.shared.deleteApp(for: app)
				}
				
				if _temporaryOptions.post_installAppAfterSigned {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
						NotificationCenter.default.post(name: Notification.Name("Feather.installApp"), object: nil)
					}
				}
				dismiss()
			}
		}
	}
}

// MARK: - Extension: Multi Open
extension SigningView {
	private func _startMultiOpen() {
		let options = _temporaryOptions
		let icon = appIcon
		let certificate = _selectedCert()
		let start = _multiOpenStart
		let count = _multiOpenCount
		let installAfter = _multiOpenInstallAfter
		let replaceOld = _multiOpenReplaceOld
		let baseIdentifier = options.appIdentifier ?? app.identifier ?? "app"

		Task { @MainActor in
			if replaceOld {
				let ids = (start..<(start + count)).map {
					MultiOpen.identifier(base: baseIdentifier, index: $0)
				}
				MultiOpen.removeSignedCopies(with: ids)
			}

			let result = await MultiOpen.signCopies(
				of: app,
				using: options,
				icon: icon,
				certificate: certificate,
				start: start,
				count: count
			) { current in
				_multiOpenProgress = current
			}

			_isSigning = false

			let finish = {
				if
					options.post_deleteAppAfterSigned,
					!app.isSigned,
					!result.identifiers.isEmpty
				{
					Storage.shared.deleteApp(for: app)
				}

				if installAfter, !result.identifiers.isEmpty {
					DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
						NotificationCenter.default.post(
							name: MultiOpen.installNotification,
							object: nil,
							userInfo: ["identifiers": result.identifiers]
						)
					}
				}
				dismiss()
			}

			if result.failures.isEmpty {
				finish()
			} else {
				let ok = UIAlertAction(title: .localized("Dismiss"), style: .cancel) { _ in
					finish()
				}
				UIAlertController.showAlert(
					title: "\(result.identifiers.count) de \(count) assinadas",
					message: result.failures.joined(separator: "\n"),
					actions: [ok]
				)
			}
		}
	}
}
