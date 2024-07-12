// Copyright 2023 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI
import SwiftUIWindowBinder

struct ListenView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @Environment(\.scenePhase) var scenePhase
	@AppStorage("newest_whisper_location_preference") var liveWindowPosition: String?

    @Binding var mode: OperatingMode
	@Binding var restart: Bool
    var conversation: ListenConversation

    @FocusState var focusField: Bool
    @StateObject private var model: ListenViewModel
	@State private var size = PreferenceData.sizeWhenListening
	@State private var magnify: Bool = PreferenceData.magnifyWhenListening
	@State private var interjecting: Bool = false
	@State private var confirmStop: Bool = false
	@State private var inBackground: Bool = false
	@State private var window: Window?

	init(mode: Binding<OperatingMode>, restart: Binding<Bool>, conversation: ListenConversation) {
        self._mode = mode
		self._restart = restart
		self.conversation = conversation
		self._model = StateObject(wrappedValue: ListenViewModel(conversation))
    }

    var body: some View {
		WindowBinder(window: $window) {
			GeometryReader { geometry in
				VStack(spacing: 10) {
					if inBackground && platformInfo == "pad" {
						backgroundView(geometry)
					} else {
						foregroundView(geometry)
					}
				}
				.multilineTextAlignment(.leading)
				.lineLimit(nil)
				.alert("Confirm Stop", isPresented: $confirmStop) {
					Button("Stop") {
						model.stop()
						mode = .ask
					}
					Button("Don't Stop") {
					}
				} message: {
					Text("Do you really want to stop \(mode == .whisper ? "whispering" : "listening")?")
				}
				.alert("Unexpected Error", isPresented: $model.connectionError) {
					ConnectionErrorButtons(mode: $mode, severity: model.connectionErrorSeverity)
				} message: {
					ConnectionErrorContent(severity: model.connectionErrorSeverity, message: model.connectionErrorDescription)
				}
				.alert("Conversation Ended", isPresented: $model.conversationEnded) {
					Button("OK") { mode = .ask }
				} message: {
					Text("The Whisperer has ended the conversation")
				}
			}
			.onAppear {
				logger.log("ListenView appeared")
				self.model.start()
				UIApplication.shared.isIdleTimerDisabled = true
			}
			.onDisappear {
				UIApplication.shared.isIdleTimerDisabled = false
				logger.log("ListenView disappeared")
				self.model.stop()
			}
			.onChange(of: model.conversationRestarted) {
				restart = true
				mode = .ask
			}
			.onChange(of: window) {
				window?.windowScene?.title = "Listening to \(model.conversationName)"
			}
			.onChange(of: model.conversationName) {
				window?.windowScene?.title = "Listening to \(model.conversationName)"
			}
			.onChange(of: scenePhase) {
				switch scenePhase {
				case .background:
					logger.log("Went to background")
					inBackground = true
					model.wentToBackground()
				case .inactive:
					logger.log("Went inactive")
					inBackground = false
					model.wentToForeground()
				case .active:
					logger.log("Went to foreground")
					inBackground = false
					model.wentToForeground()
				@unknown default:
					inBackground = false
					logger.error("Went to unknown phase: \(String(describing: scenePhase), privacy: .public)")
				}
			}
		}
    }

	private func maybeStop() {
		confirmStop = true
	}

	@ViewBuilder private func foregroundView(_ geometry: GeometryProxy) -> some View {
		ControlView(size: $size, magnify: $magnify, interjecting: $interjecting, mode: mode, maybeStop: maybeStop)
			.padding(EdgeInsets(top: listenViewTopPad, leading: sidePad, bottom: 0, trailing: sidePad))
		if (liveWindowPosition ?? "bottom" != "bottom") {
			liveView(geometry)
		} else {
			pastView(geometry)
		}
		StatusTextView(text: $model.statusText, mode: .listen, conversation: nil)
			.onTapGesture {
				if (model.whisperer == nil && !model.invites.isEmpty) {
					model.showStatusDetail = true
				}
			}
			.popover(isPresented: $model.showStatusDetail) {
				WhisperersView(model: model)
			}
		if (liveWindowPosition ?? "bottom" == "bottom") {
			liveView(geometry)
		} else {
			pastView(geometry)
		}
	}

	private func liveView(_ geometry: GeometryProxy) -> some View {
		Text(model.liveText)
			.font(FontSizes.fontFor(size))
			.truncationMode(.head)
			.textSelection(.enabled)
			.foregroundColor(colorScheme == .light ? lightLiveTextColor : darkLiveTextColor)
			.padding(innerPad)
			.frame(maxWidth: geometry.size.width,
				   maxHeight: geometry.size.height * liveTextProportion,
				   alignment: .topLeading)
			.border(colorScheme == .light ? lightLiveBorderColor : darkLiveBorderColor, width: 2)
			.padding(EdgeInsets(top: 0, leading: sidePad, bottom: listenViewBottomPad, trailing: sidePad))
			.dynamicTypeSize(magnify ? .accessibility3 : dynamicTypeSize)
	}

	private func pastView(_ geometry: GeometryProxy) -> some View {
		PastTextView(mode: .listen, model: model.pastText)
			.font(FontSizes.fontFor(size))
			.foregroundColor(colorScheme == .light ? lightPastTextColor : darkPastTextColor)
			.padding(innerPad)
			.frame(maxWidth: geometry.size.width,
				   maxHeight: geometry.size.height * pastTextProportion,
				   alignment: .bottomLeading)
			.border(colorScheme == .light ? lightPastBorderColor : darkPastBorderColor, width: 2)
			.padding(EdgeInsets(top: 0, leading: sidePad, bottom: listenViewBottomPad, trailing: sidePad))
			.dynamicTypeSize(magnify ? .accessibility3 : dynamicTypeSize)
			.textSelection(.enabled)
	}

	private func backgroundView(_ geometry: GeometryProxy) -> some View {
		VStack(alignment: .center) {
			Spacer()
			HStack {
				Spacer()
				Text("Listening to \(model.conversationName)")
					.font(.system(size: geometry.size.height / 5, weight: .bold))
					.lineLimit(nil)
					.multilineTextAlignment(.center)
					.foregroundColor(.white)
				Spacer()
			}
			Spacer()
		}
		.background(Color.accentColor)
		.ignoresSafeArea()
	}
}

struct ListenView_Previews: PreviewProvider {
	static let mode: Binding<OperatingMode> = makeBinding(.listen)
	static let restart: Binding<Bool> = makeBinding(false)

    static var previews: some View {
		ListenView(mode: mode, 
				   restart: restart,
				   conversation: UserProfile.shared.listenProfile.fromMyWhisperConversation(UserProfile.shared.whisperProfile.fallback)
				   )
    }
}
