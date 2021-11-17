//
//  MainViewController.swift
//  Orbot
//
//  Created by Benjamin Erhart on 20.05.20.
//  Copyright © 2020 Guardian Project. All rights reserved.
//

import UIKit
import Tor

class MainViewController: UIViewController {

	private static let purposeFilter = [
		TorCircuit.purposeGeneral,
		TorCircuit.purposeHsClientRend,
		TorCircuit.purposeHsServiceRend]

    @IBOutlet weak var bridgesBt: UIBarButtonItem?
	@IBOutlet weak var authBt: UIBarButtonItem?
    @IBOutlet weak var statusIcon: UIImageView!
	@IBOutlet weak var controlBt: UIButton!
	@IBOutlet weak var statusLb: UILabel!

	@IBOutlet weak var logContainer: UIView! {
		didSet {
			// Only round top right corner.
			logContainer.layer.cornerRadius = 9
			logContainer.layer.maskedCorners = [.layerMaxXMinYCorner]
		}
	}

	@IBOutlet weak var logSc: UISegmentedControl!
	@IBOutlet weak var logTv: UITextView!

	private static let nf: NumberFormatter = {
		let nf = NumberFormatter()
		nf.numberStyle = .percent
		nf.maximumFractionDigits = 1

		return nf
	}()

	private var logFsObject: DispatchSourceFileSystemObject?


	override func viewDidLoad() {
		super.viewDidLoad()

		let nc = NotificationCenter.default

		nc.addObserver(self, selector: #selector(updateUi), name: .vpnStatusChanged, object: nil)
		nc.addObserver(self, selector: #selector(updateUi), name: .vpnProgress, object: nil)

		updateUi()
	}


	// MARK: Actions

	@IBAction func toggleLogs() {
		if logContainer.isHidden {
			logContainer.transform = CGAffineTransform(translationX: -logContainer.bounds.width, y: 0)
			logContainer.isHidden = false

			UIView.animate(withDuration: 0.5) {
				self.logContainer.transform = CGAffineTransform(translationX: 0, y: 0)
			} completion: { _ in
				self.changeLog()
			}
		}
		else {
			hideLogs()
		}
	}

	@IBAction func hideLogs() {
		if !logContainer.isHidden {
			UIView.animate(withDuration: 0.5) {
				self.logContainer.transform = CGAffineTransform(translationX: -self.logContainer.bounds.width, y: 0)
			} completion: { _ in
				self.logContainer.isHidden = true
				self.logContainer.transform = CGAffineTransform(translationX: 0, y: 0)

				self.logFsObject?.cancel()
				self.logFsObject = nil
			}
		}
	}

	@IBAction func changeBridge(_ sender: UIBarButtonItem? = nil) {
		present(inNav: BridgeConfViewController(), button: sender ?? bridgesBt)
	}

    @IBAction func showAuth(_ sender: UIBarButtonItem) {
		showAuth(button: sender)
	}

	@discardableResult
	func showAuth(button: UIBarButtonItem? = nil) -> AuthViewController {
		let vc = AuthViewController(style: .grouped)

		present(inNav: vc, button: button ?? authBt)

		return vc
	}

	@IBAction func control() {

		// Enable, if disabled.
		if VpnManager.shared.confStatus == .disabled {
			return VpnManager.shared.enable { [weak self] success in
				if success && VpnManager.shared.confStatus == .enabled {
					self?.control()
				}
			}
		}
		// Install first, if not installed.
		else if VpnManager.shared.confStatus == .notInstalled {
			return VpnManager.shared.install()
		}

		switch VpnManager.shared.sessionStatus {
		case .connected, .connecting:
			VpnManager.shared.disconnect()

		case .disconnected, .disconnecting:
			VpnManager.shared.connect()

		default:
			break
		}
	}

	@IBAction func changeLog() {
		switch logSc.selectedSegmentIndex {
		case 1:
			logFsObject?.cancel()
			logFsObject = nil

			logTv.text = nil

			VpnManager.shared.getCircuits { [weak self] circuits, error in
				var text = ""

				var i = 1

				for c in circuits {
					if c.purpose == nil
						|| !Self.purposeFilter.contains(c.purpose!)
						|| c.buildFlags?.contains(TorCircuit.buildFlagIsInternal) ?? false
						|| c.buildFlags?.contains(TorCircuit.buildFlagOneHopTunnel) ?? false
						|| c.nodes?.isEmpty ?? true
					{
						continue
					}

					text += "Circuit \(c.circuitId ?? String(i))\n"

					var j = 1

					for n in c.nodes ?? [] {
						var country = n.localizedCountryName ?? n.countryCode ?? ""

						if !country.isEmpty {
							country = " (\(country))"
						}

						text += "\(j): \(n.nickName ?? n.fingerprint ?? n.ipv4Address ?? n.ipv6Address ?? "unknown node")\(country)\n"

						j += 1
					}

					text += "\n"

					i += 1
				}

				self?.logTv.text = text
				self?.logTv.scrollToBottom()
			}

		case 2:
			// Shows the content of the leaf config file.
			// Only for development!
			logFsObject?.cancel()
			logFsObject = nil

			logTv.text = nil

			if let url = FileManager.default.leafConfFile {
				logTv.text = try? String(contentsOf: url)
			}

		default:
			createLogFsObject()
		}
	}


	// MARK: Observers

	@objc func updateUi(_ notification: Notification? = nil) {

		switch VpnManager.shared.sessionStatus {
		case .connected, .connecting:
			statusIcon.image = UIImage(named: "TorOn")
			controlBt.setTitle(NSLocalizedString("Stop", comment: ""))

		case .invalid:
			statusIcon.image = UIImage(named: "TorOff")
			controlBt.setTitle(NSLocalizedString("Install", comment: ""))

		default:
			statusIcon.image = UIImage(named: "TorOff")
			controlBt.setTitle(NSLocalizedString("Start", comment: ""))
		}

		if let error = VpnManager.shared.error {
			statusLb.textColor = .systemRed
			statusLb.text = error.localizedDescription
		}
		else if VpnManager.shared.confStatus != .enabled {
			statusLb.textColor = .white
			statusLb.text = VpnManager.shared.confStatus.description
		}
		else {
			var progress = ""

			if notification?.name == .vpnProgress,
			   let raw = notification?.object as? Float {

				progress = MainViewController.nf.string(from: NSNumber(value: raw)) ?? ""
			}

			var bridge = ""

			switch VpnManager.shared.sessionStatus {
			case .connected, .connecting, .reasserting:
				bridge = Settings.bridge.description

			default:
				break
			}

			statusLb.textColor = .white
			statusLb.text = [VpnManager.shared.sessionStatus.description,
							 bridge, progress].joined(separator: " ")
		}
	}


	// MARK: Private Methods

	private func createLogFsObject() {
		guard logFsObject == nil,
			let url = FileManager.default.torLogFile,
			let fh = try? FileHandle(forReadingFrom: url)
		else {
			return
		}

		let ui = { [weak self] in
			let data = fh.readDataToEndOfFile()
			self?.logTv.text = (self?.logTv.text ?? "") + (String(data: data, encoding: .utf8) ?? "")
			self?.logTv.scrollToBottom()
		}

		logTv.text = nil
		ui()

		logFsObject = DispatchSource.makeFileSystemObjectSource(
			fileDescriptor: fh.fileDescriptor,
			eventMask: [.extend, .delete, .link],
			queue: .main)

		logFsObject?.setEventHandler { [weak self] in
			guard let data = self?.logFsObject?.data else {
				return
			}

			if data.contains(.delete) || data.contains(.link) {
				self?.logFsObject?.cancel()
				self?.logFsObject = nil
				self?.createLogFsObject()
			}

			if data.contains(.extend) {
				ui()
			}
		}

		logFsObject?.setCancelHandler {
			try? fh.close()
		}

		logFsObject?.resume()
	}
}
