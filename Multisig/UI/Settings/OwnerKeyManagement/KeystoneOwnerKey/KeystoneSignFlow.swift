//
//  KeystoneSignFlow.swift
//  Multisig
//
//  Created by Zhiying Fan on 6/9/2022.
//  Copyright © 2022 Gnosis Ltd. All rights reserved.
//

import Foundation
import SwiftUI
import URRegistry

class KeystoneSignFlow: UIFlow {
    private let signRequest: KeystoneSignRequest
    private let chain: Chain?
    
    var signCompletion: ((_ signature: String) -> Void)?
    
    init(signRequest: KeystoneSignRequest, chain: Chain?, completion: @escaping (Bool) -> Void) {
        self.signRequest = signRequest
        self.chain = chain
        super.init(completion: completion)
    }
    
    override func start() {
        requestSignature()
    }
    
    private func requestSignature() {
        guard let qrValue = URRegistry.shared.requestSign(signRequest: signRequest) else {
            stop(success: false)
            return
        }
        let signVC = UIHostingController(rootView: KeystoneRequestSignatureView(qrValue: qrValue, onTap: { [weak self] in
            self?.presentScanner()
        }))
        signVC.navigationItem.title = "Request signature"
        
        let ribbon = ViewControllerFactory.ribbonWith(viewController: signVC)
        ribbon.storedChain = chain

        show(ribbon)
    }
    
    private func presentScanner() {
        let vc = QRCodeScannerViewController()

        let string = "Scan the QR code on the Keystone wallet to confirm the transaction." as NSString
        let textStyle = GNOTextStyle.primary.color(.white)
        let highlightStyle = textStyle.weight(.bold)
        let label = NSMutableAttributedString(string: string as String, attributes: textStyle.attributes)
        label.setAttributes(highlightStyle.attributes, range: string.range(of: "confirm the transaction"))
        vc.attributedLabel = label

        vc.scannedValueValidator = { value in
            guard value.starts(with: "UR:ETH-SIGNATURE") else {
                return .failure(GSError.InvalidWalletConnectQRCode())
            }
            return .success(value)
        }
        vc.modalPresentationStyle = .overFullScreen
        vc.delegate = self
        vc.setup()
        
        navigationController.present(vc, animated: true)
    }
}

extension KeystoneSignFlow: QRCodeScannerViewControllerDelegate {
    func scannerViewControllerDidScan(_ code: String) {
        guard let signature = URRegistry.shared.getSignature(from: code) else {
            stop(success: false)
            return
        }
        
        signCompletion?(signature)
        stop(success: true)
    }
    
    func scannerViewControllerDidCancel() {
        stop(success: false)
    }
}
