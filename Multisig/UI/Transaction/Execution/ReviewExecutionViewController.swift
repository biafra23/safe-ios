//
//  ReviewExecutionViewController.swift
//  Multisig
//
//  Created by Dmitry Bespalov on 11.01.22.
//  Copyright © 2022 Gnosis Ltd. All rights reserved.
//

import UIKit
import Ethereum
import SwiftCryptoTokenFormatter

// wrapper around the content
class ReviewExecutionViewController: ContainerViewController {

    private var safe: Safe!
    private var chain: Chain!
    private var transaction: SCGModels.TransactionDetails!

    private var controller: TransactionExecutionController!

    private var onClose: () -> Void = { }

    private var contentVC: ReviewExecutionContentViewController!

    @IBOutlet weak var ribbonView: RibbonView!
    @IBOutlet weak var contentView: UIView!
    @IBOutlet weak var submitButton: UIButton!

    var closeButton: UIBarButtonItem!

    private var defaultKeyTask: URLSessionTask?
    private var txEstimationTask: URLSessionTask?

    convenience init(safe: Safe, chain: Chain, transaction: SCGModels.TransactionDetails, onClose: @escaping () -> Void) {
        // create from the nib named as the self's class name
        self.init(namedClass: nil)
        self.safe = safe
        self.chain = chain
        self.transaction = transaction
        self.onClose = onClose
        self.controller = TransactionExecutionController(safe: safe, chain: chain, transaction: transaction)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        assert(safe != nil)
        assert(chain != nil)
        assert(transaction != nil)

        title = "Execute"

        // configure content
        contentVC = ReviewExecutionContentViewController(
            safe: safe,
            chain: chain,
            transaction: transaction)
        contentVC.onTapAccount = action(#selector(didTapAccount(_:)))
        contentVC.onTapFee = action(#selector(didTapFee(_:)))
        contentVC.onTapAdvanced = action(#selector(didTapAdvanced(_:)))
        contentVC.model = ExecutionReviewUIModel(
            transaction: transaction,
            executionOptions: ExecutionOptionsUIModel(
                accountState: .loading,
                feeState: .loading
            )
        )
        self.viewControllers = [contentVC]
        self.displayChild(at: 0, in: contentView)


        // configure ribbon view
        ribbonView.update(chain: chain)

        // configure submit button
        submitButton.setText("Submit", .filled)
        submitButton.isEnabled = controller.isValid

        // configure close button
        closeButton = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(didTapClose(_:)))

        navigationItem.leftBarButtonItem = closeButton

        estimateTransaction()
    }

    func action(_ selector: Selector) -> () -> Void {
        { [weak self] in
            self?.performSelector(onMainThread: selector, with: nil, waitUntilDone: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // tracking
    }


    @IBAction func didTapClose(_ sender: Any) {
        self.onClose()
    }

    @IBAction func didTapAccount(_ sender: Any) {
        let keys = controller.executionKeys()
        let balancesLoader = DefaultAccountBalanceLoader(chain: chain)

        let keyPickerVC = ChooseOwnerKeyViewController(
            owners: keys,
            chainID: controller.chainId,
            titleText: "Select an execution key",
            descriptionText: "The selected key will be used to execute this transaction.",
            requestsPasscode: false,
            selectedKey: controller.selectedKey?.key,
            balancesLoader: balancesLoader
        )
        // this way of returning the results from the view controller is just because
        // there was already existing code depending on the completion handler.
        // modified with minimum changes to the existing API.
        let completion: (KeyInfo?) -> Void = { [weak self, weak keyPickerVC] selectedKeyInfo in
            guard let self = self, let picker = keyPickerVC else { return }
            let balance = selectedKeyInfo.flatMap { picker.accountBalance(for: $0) }

            let previousKey = self.controller.selectedKey?.key
            // update selection
            if let key = selectedKeyInfo, let balance = balance {
                self.controller.selectedKey = (key, balance)
            } else {
                self.controller.selectedKey = nil
            }
            if selectedKeyInfo != previousKey {
                self.didChangeSelectedKey()
            }

            self.dismiss(animated: true)
        }
        keyPickerVC.completionHandler = completion

        let navigationController = UINavigationController(rootViewController: keyPickerVC)
        present(navigationController, animated: true)
    }

    @IBAction func didTapFee(_ sender: Any) {
        let formModel: FormModel
        var initialValues = UserDefinedTransactionParameters()

        switch controller.ethTransaction {
        case let ethTx as Eth.TransactionLegacy:
            let model = FeeLegacyFormModel(
                nonce: ethTx.nonce,
                gas: ethTx.fee.gas,
                gasPriceInWei: ethTx.fee.gasPrice,
                nativeCurrency: chain.nativeCurrency!
            )
            initialValues.nonce = model.nonce
            initialValues.gas = model.gas
            initialValues.gasPrice = model.gasPriceInWei

            formModel = model

        case let ethTx as Eth.TransactionEip1559:
            let model = Fee1559FormModel(
                nonce: ethTx.nonce,
                gas: ethTx.fee.gas,
                maxFeePerGasInWei: ethTx.fee.maxFeePerGas,
                maxPriorityFeePerGasInWei: ethTx.fee.maxPriorityFee,
                nativeCurrency: chain.nativeCurrency!
            )
            initialValues.nonce = model.nonce
            initialValues.gas = model.gas
            initialValues.maxFeePerGas = model.maxFeePerGasInWei
            initialValues.maxPriorityFee = model.maxPriorityFeePerGasInWei

            formModel = model

        default:
            if chain.features?.contains("EIP1559") == true {
                formModel = Fee1559FormModel(
                    nonce: nil,
                    gas: nil,
                    maxFeePerGasInWei: nil,
                    maxPriorityFeePerGasInWei: nil,
                    nativeCurrency: chain.nativeCurrency!
                )
            } else {
                formModel = FeeLegacyFormModel(
                    nonce: nil,
                    gas: nil,
                    gasPriceInWei: nil,
                    nativeCurrency: chain.nativeCurrency!
                )
            }
        }

        let formVC = FormViewController(model: formModel) { [weak self] in
            // on close - ignore any changes
            self?.dismiss(animated: true)
        }

        formVC.onSave = { [weak self, weak formModel] in
            // on save - update the parameters that were changed.
            self?.dismiss(animated: true, completion: {
                guard let self = self, let formModel = formModel else { return }

                // collect the saved values

                var savedValues = UserDefinedTransactionParameters()

                switch formModel {
                case let model as FeeLegacyFormModel:
                    savedValues.nonce = model.nonce
                    savedValues.gas = model.gas
                    savedValues.gasPrice = model.gasPriceInWei

                case let model as Fee1559FormModel:
                    savedValues.nonce = model.nonce
                    savedValues.gas = model.gas
                    savedValues.maxFeePerGas = model.maxFeePerGasInWei
                    savedValues.maxPriorityFee = model.maxPriorityFeePerGasInWei

                default:
                    break
                }

                // compare the initial snapshot and saved snapshot
                // memberwise and remember only those values that changed.

                if savedValues.nonce != initialValues.nonce {
                    self.controller.userParameters.nonce = savedValues.nonce
                }

                if savedValues.gas != initialValues.gas {
                    self.controller.userParameters.gas = savedValues.gas
                }

                if savedValues.gasPrice != initialValues.gasPrice {
                    self.controller.userParameters.gasPrice = savedValues.gasPrice
                }

                if savedValues.maxFeePerGas != initialValues.maxFeePerGas {
                    self.controller.userParameters.maxFeePerGas = savedValues.maxFeePerGas
                }

                if savedValues.maxPriorityFee != initialValues.maxPriorityFee {
                    self.controller.userParameters.maxPriorityFee = savedValues.maxPriorityFee
                }

                // react to changes

                if savedValues != initialValues {
                    self.didChangeTransactionParameters()
                }
            })
        }

        formVC.navigationItem.title = "Edit transaction fee"

        let nav = UINavigationController(rootViewController: formVC)
        present(nav, animated: true, completion: nil)
    }

    @IBAction func didTapAdvanced(_ sender: Any) {
        let advancedVC = AdvancedTransactionDetailsViewController(transaction, chain: chain)
        show(advancedVC, sender: self)
    }

    @IBAction func didTapSubmit(_ sender: Any) {
        print("Submit!")
    }

    func estimateTransaction() {
        txEstimationTask?.cancel()
        resetErrors()

        contentVC.model?.executionOptions.feeState = .loading

        let task = controller.estimate { [weak self] error in
            guard let self = self else { return }
            // TODO: display estimation error
            self.didChangeEstimation()

            // if we haven't search default
            if !self.didSearchDefaultKey && self.controller.selectedKey == nil {
                self.findDefaultKey()
            }
        }

        txEstimationTask = task
    }

    var didSearchDefaultKey: Bool = false

    func findDefaultKey() {
        resetErrors()
        defaultKeyTask?.cancel()

        self.contentVC.model?.executionOptions.accountState = .loading

        let previousKey = self.controller.selectedKey?.key

        let task = controller.findDefaultKey { [weak self] in
            guard let self = self else { return }
            self.didSearchDefaultKey = true
            if previousKey != self.controller.selectedKey?.key {
                self.didChangeSelectedKey()
            }
        }

        self.defaultKeyTask = task
    }

    func didChangeSelectedKey() {
        if let selection = controller.selectedKey {
            let model = MiniAccountInfoUIModel(
                prefix: self.chain.shortName,
                address: selection.key.address,
                label: selection.key.name,
                imageUri: nil,
                badge: selection.key.keyType.imageName,
                balance: selection.balance.displayAmount
            )
            self.contentVC.model?.executionOptions.accountState = .filled(model)

            // re-estimate if the key changed.
            estimateTransaction()
        } else {
            contentVC.model?.executionOptions.accountState = .empty
        }

        validate()
    }

    func didChangeTransactionParameters() {
        didChangeEstimation()
    }

    func didChangeEstimation() {
        if let tx = controller.ethTransaction {

            let feeInWei = tx.totalFee

            let nativeCoinDecimals = chain.nativeCurrency!.decimals
            let nativeCoinSymbol = chain.nativeCurrency!.symbol!

            let decimalAmount = BigDecimal(Int256(feeInWei.big()), Int(nativeCoinDecimals))
            let value = TokenFormatter().string(
                from: decimalAmount,
                decimalSeparator: Locale.autoupdatingCurrent.decimalSeparator ?? ".",
                thousandSeparator: Locale.autoupdatingCurrent.groupingSeparator ?? ",",
                forcePlusSign: false
            )

            let tokenAmount: String = "\(value) \(nativeCoinSymbol)"

            // TODO: fetch fiat amount

            let model = EstimatedFeeUIModel(
                tokenAmount: tokenAmount,
                fiatAmount: nil)

            contentVC.model?.executionOptions.feeState = .loaded(model)
        } else {
            contentVC.model?.executionOptions.feeState = .empty
        }

        validate()
    }

    func resetErrors() {
        controller.errorMessage = nil
        contentVC?.model?.errorMessage = nil
    }

    func validate() {
        resetErrors()
        controller.validate()
        contentVC?.model?.errorMessage = controller.errorMessage
        submitButton.isEnabled = controller.isValid
    }

}
