// Copyright 2021 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import BraveCore
import SwiftUI

public struct AssetViewModel: Identifiable, Equatable {
  var token: BraveWallet.BlockchainToken
  var network: BraveWallet.NetworkInfo
  var decimalBalance: Double
  var price: String
  var history: [BraveWallet.AssetTimePrice]

  public var id: String {
    token.id + network.chainId
  }
}

struct NFTAssetViewModel: Identifiable, Equatable {
  var token: BraveWallet.BlockchainToken
  var network: BraveWallet.NetworkInfo
  var balance: Int
  var erc721Metadata: ERC721Metadata?

  public var id: String {
    token.id + network.chainId
  }
  
  static func == (lhs: NFTAssetViewModel, rhs: NFTAssetViewModel) -> Bool {
    lhs.id == rhs.id
  }
}

struct BalanceTimePrice: DataPoint, Equatable {
  var date: Date
  var price: Double
  var formattedPrice: String

  var value: CGFloat {
    price
  }
}

public enum NetworkFilter: Equatable {
  case allNetworks
  case network(BraveWallet.NetworkInfo)
  
  var title: String {
    switch self {
    case .allNetworks:
      return Strings.Wallet.allNetworksTitle
    case let .network(network):
      return network.chainName
    }
  }
}

/// A store containing data around the users assets
public class PortfolioStore: ObservableObject {
  /// The dollar amount of your portfolio
  @Published private(set) var balance: String = "$0.00"
  /// The users visible fungible tokens. NFTs are separated into `userVisibleNFTs`.
  @Published private(set) var userVisibleAssets: [AssetViewModel] = []
  /// The users visible NFTs
  @Published private(set) var userVisibleNFTs: [NFTAssetViewModel] = []
  /// The timeframe of the portfolio
  @Published var timeframe: BraveWallet.AssetPriceTimeframe = .oneDay {
    didSet {
      if timeframe != oldValue {
        update()
      }
    }
  }
  /// A set of balances of your portfolio's visible assets based on `timeframe`
  @Published private(set) var historicalBalances: [BalanceTimePrice] = []
  /// Whether or not balances are still currently loading
  @Published private(set) var isLoadingBalances: Bool = false
  /// The current default base currency code
  @Published private(set) var currencyCode: String = CurrencyCode.usd.code {
    didSet {
      currencyFormatter.currencyCode = currencyCode
      guard oldValue != currencyCode else { return }
      update()
    }
  }
  
  @Published var networkFilter: NetworkFilter = .allNetworks {
    didSet {
      update()
    }
  }

  public private(set) lazy var userAssetsStore: UserAssetsStore = .init(
    walletService: self.walletService,
    blockchainRegistry: self.blockchainRegistry,
    rpcService: self.rpcService,
    keyringService: self.keyringService,
    assetRatioService: self.assetRatioService
  )
  
  let currencyFormatter: NumberFormatter = .usdCurrencyFormatter
  
  /// Cancellable for the last running `update()` Task.
  private var updateTask: Task<(), Never>?
  /// Cache of total balances. The key is the token's `assetBalanceId`.
  private var totalBalancesCache: [String: Double] = [:]
  /// Cache of prices for each token. The key is the token's `assetRatioId`.
  private var pricesCache: [String: String] = [:]
  /// Cache of priceHistories. The key is the token's `assetRatioId`.
  private var priceHistoriesCache: [String: [BraveWallet.AssetTimePrice]] = [:]
  /// Cache of metadata for erc721 token. The key is the token's `id`.
  private var metadataCache: [String: ERC721Metadata] = [:]

  private let keyringService: BraveWalletKeyringService
  private let rpcService: BraveWalletJsonRpcService
  private let walletService: BraveWalletBraveWalletService
  private let assetRatioService: BraveWalletAssetRatioService
  private let blockchainRegistry: BraveWalletBlockchainRegistry

  public init(
    keyringService: BraveWalletKeyringService,
    rpcService: BraveWalletJsonRpcService,
    walletService: BraveWalletBraveWalletService,
    assetRatioService: BraveWalletAssetRatioService,
    blockchainRegistry: BraveWalletBlockchainRegistry
  ) {
    self.keyringService = keyringService
    self.rpcService = rpcService
    self.walletService = walletService
    self.assetRatioService = assetRatioService
    self.blockchainRegistry = blockchainRegistry

    self.rpcService.add(self)
    self.keyringService.add(self)
    self.walletService.add(self)

    keyringService.isLocked { [self] isLocked in
      if !isLocked {
        update()
      }
    }
    walletService.defaultBaseCurrency { [self] currencyCode in
      self.currencyCode = currencyCode
    }
  }
  
  func update() {
    self.updateTask?.cancel()
    self.updateTask = Task { @MainActor in
      self.isLoadingBalances = true
      let networks: [BraveWallet.NetworkInfo]
      switch networkFilter {
      case .allNetworks:
        networks = await self.rpcService.allNetworksForSupportedCoins()
          .filter { !WalletConstants.supportedTestNetworkChainIds.contains($0.chainId) }
      case let .network(network):
        networks = [network]
      }
      struct NetworkAssets: Equatable {
        let network: BraveWallet.NetworkInfo
        let tokens: [BraveWallet.BlockchainToken]
        let sortOrder: Int
      }
      let allVisibleUserAssets = await self.walletService.allVisibleUserAssets(in: networks)
      var updatedUserVisibleAssets: [AssetViewModel] = []
      var updatedUserVisibleNFTs: [NFTAssetViewModel] = []
      for networkAssets in allVisibleUserAssets {
        for token in networkAssets.tokens {
          if token.isErc721 || token.isNft {
            updatedUserVisibleNFTs.append(
              NFTAssetViewModel(
                token: token,
                network: networkAssets.network,
                balance: Int(totalBalancesCache[token.assetBalanceId] ?? 0),
                erc721Metadata: metadataCache[token.id]
              )
            )
          } else {
            updatedUserVisibleAssets.append(
              AssetViewModel(
                token: token,
                network: networkAssets.network,
                decimalBalance: totalBalancesCache[token.assetBalanceId] ?? 0,
                price: pricesCache[token.assetRatioId.lowercased()] ?? "",
                history: priceHistoriesCache[token.assetRatioId.lowercased()] ?? []
              )
            )
          }
        }
      }
      // update userVisibleAssets on display immediately with empty values. Issue #5567
      self.userVisibleAssets = updatedUserVisibleAssets
      self.userVisibleNFTs = updatedUserVisibleNFTs
      
      let keyrings = await self.keyringService.keyrings(for: WalletConstants.supportedCoinTypes)
      guard !Task.isCancelled else { return }
      typealias TokenNetworkAccounts = (token: BraveWallet.BlockchainToken, network: BraveWallet.NetworkInfo, accounts: [BraveWallet.AccountInfo])
      let allTokenNetworkAccounts = allVisibleUserAssets.flatMap { networkAssets in
        networkAssets.tokens.map { token in
          TokenNetworkAccounts(
            token: token,
            network: networkAssets.network,
            accounts: keyrings.first(where: { $0.coin == token.coin })?.accountInfos ?? []
          )
        }
      }
      let totalBalances: [String: Double] = await withTaskGroup(of: [String: Double].self, body: { @MainActor group in
        for tokenNetworkAccounts in allTokenNetworkAccounts {
          group.addTask { @MainActor in
            let totalBalance = await self.rpcService.fetchTotalBalance(
              token: tokenNetworkAccounts.token,
              network: tokenNetworkAccounts.network,
              accounts: tokenNetworkAccounts.accounts
            )
            return [tokenNetworkAccounts.token.assetBalanceId: totalBalance]
          }
        }
        return await group.reduce(into: [String: Double](), { partialResult, new in
          for key in new.keys {
            partialResult[key] = new[key]
          }
        })
      })
      for (key, value) in totalBalances {
        totalBalancesCache[key] = value
      }

      // fetch price for every token
      let allTokens = allVisibleUserAssets.flatMap(\.tokens)
      let allAssetRatioIds = allTokens.map(\.assetRatioId)
      let prices: [String: String] = await assetRatioService.fetchPrices(
        for: allAssetRatioIds,
        toAssets: [currencyFormatter.currencyCode],
        timeframe: timeframe
      )
      for (key, value) in prices { // update cached values
        self.pricesCache[key] = value
      }

      // fetch price history for every non-zero balance token
      let nonZeroBalanceAssetRatioIds: [String] = allTokens
        .filter { (totalBalancesCache[$0.assetBalanceId] ?? 0) > 0 }
        .map { $0.assetRatioId }
      let priceHistories: [String: [BraveWallet.AssetTimePrice]] = await fetchPriceHistory(for: nonZeroBalanceAssetRatioIds)
      for (key, value) in priceHistories { // update cached values
        self.priceHistoriesCache[key] = value
      }
      
      // fetch ERC721 metadata for ERC721 tokens
      let erc721Tokens = allTokens.filter { $0.isErc721 }
      let allMetadata = await rpcService.fetchERC721Metadata(tokens: erc721Tokens)
      for (key, value) in allMetadata { // update cached values
        metadataCache[key] = value
      }
      
      guard !Task.isCancelled else { return }
      updatedUserVisibleAssets.removeAll()
      updatedUserVisibleNFTs.removeAll()
      for networkAssets in allVisibleUserAssets {
        for token in networkAssets.tokens {
          if token.isErc721 || token.isNft {
            updatedUserVisibleNFTs.append(
              NFTAssetViewModel(
                token: token,
                network: networkAssets.network,
                balance: Int(totalBalancesCache[token.assetBalanceId] ?? 0),
                erc721Metadata: metadataCache[token.id]
              )
            )
          } else {
            updatedUserVisibleAssets.append(
              AssetViewModel(
                token: token,
                network: networkAssets.network,
                decimalBalance: totalBalancesCache[token.assetBalanceId] ?? 0,
                price: pricesCache[token.assetRatioId.lowercased()] ?? "",
                history: priceHistoriesCache[token.assetRatioId.lowercased()] ?? []
              )
            )
          }
        }
      }
      self.userVisibleAssets = updatedUserVisibleAssets
      self.userVisibleNFTs = updatedUserVisibleNFTs
      
      // Compute balance based on current prices
      let currentBalance = userVisibleAssets
        .compactMap {
          if let price = Double($0.price) {
            return $0.decimalBalance * price
          }
          return nil
        }
        .reduce(0.0, +)
      balance = currencyFormatter.string(from: NSNumber(value: currentBalance)) ?? "–"
      // Compute historical balances based on historical prices and current balances
      let assets = userVisibleAssets.filter { !$0.history.isEmpty }  // [[AssetTimePrice]]
      let minCount = assets.map(\.history.count).min() ?? 0  // Shortest array count
      historicalBalances = (0..<minCount).map { index in
        let value = assets.reduce(0.0, {
          $0 + ((Double($1.history[index].price) ?? 0.0) * $1.decimalBalance)
        })
        return .init(
          date: assets.map { $0.history[index].date }.max() ?? .init(),
          price: value,
          formattedPrice: currencyFormatter.string(from: NSNumber(value: value)) ?? "0.00"
        )
      }
      isLoadingBalances = false
    }
  }
  
  /// Fetches the price history for the given `assetRatioId`, giving a dictionary with the price history for each symbol
  @MainActor func fetchPriceHistory(
    for priceIds: [String]
  ) async -> [String: [BraveWallet.AssetTimePrice]] {
    let uniquePriceIds = Set(priceIds)
    let priceHistories = await withTaskGroup(of: [String: [BraveWallet.AssetTimePrice]].self) { @MainActor group -> [String: [BraveWallet.AssetTimePrice]] in
      for priceId in uniquePriceIds {
        let priceId = priceId.lowercased()
        group.addTask { @MainActor in
          let (success, history) = await self.assetRatioService.priceHistory(
            priceId,
            vsAsset: self.currencyFormatter.currencyCode,
            timeframe: self.timeframe
          )
          if success {
            return [priceId: history.sorted(by: { $0.date < $1.date })]
          } else {
            return [:]
          }
        }
      }
      return await group.reduce(into: [String: [BraveWallet.AssetTimePrice]](), { partialResult, new in
        for key in new.keys {
          partialResult[key] = new[key]
        }
      })
    }
    return priceHistories
  }
  
  func updateERC721MetadataCache(for token: BraveWallet.BlockchainToken, metadata: ERC721Metadata) {
    metadataCache[token.id] = metadata
    if let index = userVisibleNFTs.firstIndex(where: { $0.token.id == token.id }), let viewModel = userVisibleNFTs[safe: index] {
      userVisibleNFTs[index] = NFTAssetViewModel(token: viewModel.token, network: viewModel.network, balance: viewModel.balance, erc721Metadata: metadata)
    }
  }
}

extension PortfolioStore: BraveWalletJsonRpcServiceObserver {
  public func onIsEip1559Changed(_ chainId: String, isEip1559: Bool) {
  }

  public func onAddEthereumChainRequestCompleted(_ chainId: String, error: String) {
  }

  public func chainChangedEvent(_ chainId: String, coin: BraveWallet.CoinType) {
    update()
  }
}

extension PortfolioStore: BraveWalletKeyringServiceObserver {
  public func keyringReset() {
  }

  public func accountsChanged() {
    update()
  }
  public func backedUp() {
  }
  public func keyringCreated(_ keyringId: String) {
  }
  public func keyringRestored(_ keyringId: String) {
  }
  public func locked() {
  }
  public func unlocked() {
    DispatchQueue.main.async { [self] in
      update()
    }
  }
  public func autoLockMinutesChanged() {
  }
  public func selectedAccountChanged(_ coinType: BraveWallet.CoinType) {
    DispatchQueue.main.async { [self] in
      update()
    }
  }
  
  public func accountsAdded(_ coin: BraveWallet.CoinType, addresses: [String]) {
  }
}

extension PortfolioStore: BraveWalletBraveWalletServiceObserver {
  public func onActiveOriginChanged(_ originInfo: BraveWallet.OriginInfo) {
  }

  public func onDefaultWalletChanged(_ wallet: BraveWallet.DefaultWallet) {
  }

  public func onDefaultBaseCurrencyChanged(_ currency: String) {
    currencyCode = currency
  }

  public func onDefaultBaseCryptocurrencyChanged(_ cryptocurrency: String) {
  }

  public func onNetworkListChanged() {
  }
  
  public func onDefaultEthereumWalletChanged(_ wallet: BraveWallet.DefaultWallet) {
  }
  
  public func onDefaultSolanaWalletChanged(_ wallet: BraveWallet.DefaultWallet) {
  }
  
  public func onDiscoverAssetsCompleted(_ discoveredAssets: [BraveWallet.BlockchainToken]) {
  }
}
