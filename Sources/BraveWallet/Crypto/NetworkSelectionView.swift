/* Copyright 2021 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import BraveCore
import DesignSystem
import SwiftUI
import BraveUI

struct NetworkSelectionView: View {
  
  var keyringStore: KeyringStore
  @ObservedObject var networkStore: NetworkStore
  @ObservedObject var store: NetworkSelectionStore
  @Environment(\.presentationMode) @Binding private var presentationMode
  
  init(
    keyringStore: KeyringStore,
    networkStore: NetworkStore,
    networkSelectionStore: NetworkSelectionStore
  ) {
    self.keyringStore = keyringStore
    self.networkStore = networkStore
    self.store = networkSelectionStore
  }
  
  private var selectedNetwork: NetworkPresentation.Network {
    switch store.mode {
    case .select:
      return .network(networkStore.selectedChain)
    case .formSelection:
      return .network(store.networkSelectionInForm ?? .init())
    }
  }
  
  private var navigationTitle: String {
    switch store.mode {
    case .select: return Strings.Wallet.networkSelectionTitle
    case .formSelection: return Strings.Wallet.networkSelectionTitle
    }
  }
  
  var body: some View {
    NetworkSelectionRootView(
      navigationTitle: navigationTitle,
      selectedNetwork: selectedNetwork,
      primaryNetworks: store.primaryNetworks,
      secondaryNetworks: store.secondaryNetworks,
      selectNetwork: { network in
        selectNetwork(network)
      }
    )
    .onAppear {
      store.update()
    }
    .background(
      Color.clear
        .alert(
          isPresented: $store.isPresentingNextNetworkAlert
        ) {
          Alert(
            title: Text(String.localizedStringWithFormat(Strings.Wallet.createAccountAlertTitle, store.nextNetwork?.shortChainName ?? "")),
            message: Text(Strings.Wallet.createAccountAlertMessage),
            primaryButton: .default(Text(Strings.yes), action: {
              store.handleCreateAccountAlertResponse(shouldCreateAccount: true)
            }),
            secondaryButton: .cancel(Text(Strings.no), action: {
              store.handleCreateAccountAlertResponse(shouldCreateAccount: false)
            })
          )
        }
    )
    .background(
      Color.clear
        .sheet(
          isPresented: $store.isPresentingAddAccount
        ) {
          NavigationView {
            AddAccountView(keyringStore: keyringStore, preSelectedCoin: store.nextNetwork?.coin)
          }
          .navigationViewStyle(.stack)
          .onDisappear {
            Task { @MainActor in
              if await store.handleDismissAddAccount() {
                presentationMode.dismiss()
              }
            }
          }
        }
    )
  }
  
  private func selectNetwork(_ presentation: NetworkPresentation.Network) {
    Task { @MainActor in
      if await store.selectNetwork(presentation) {
        presentationMode.dismiss()
      }
    }
  }
}
