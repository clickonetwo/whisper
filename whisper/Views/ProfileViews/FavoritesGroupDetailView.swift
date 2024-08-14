// Copyright 2024 Daniel C Brotsky.  All rights reserved.
//
// All material in this project and repository is licensed under the
// GNU Affero General Public License v3. See the LICENSE file for details.

import SwiftUI

struct FavoritesGroupDetailView: View {
#if targetEnvironment(macCatalyst)
	@Environment(\.dismiss) private var dismiss
#endif

	@Binding var path: NavigationPath
	var g: FavoritesGroup

	@State var name: String = ""
	@State var newName: String = ""
	@State var favorites: [Favorite] = []
	@StateObject private var up = UserProfile.shared
	@StateObject private var fp = UserProfile.shared.favoritesProfile

	var body: some View {
		Form {
			Section(header: Text("Group Name")) {
				if g === fp.allGroup {
					Text(name)
						.lineLimit(nil)
				} else {
					HStack (spacing: 15) {
						TextField("Group Name", text: $newName)
							.lineLimit(nil)
							.submitLabel(.done)
							.textInputAutocapitalization(.never)
							.disableAutocorrection(true)
							.onSubmit { updateTag() }
						Button("Submit", systemImage: "checkmark.square.fill") { updateTag() }
							.labelStyle(.iconOnly)
							.disabled(newName.isEmpty || newName == g.name)
						Button("Reset", systemImage: "x.square.fill") { newName = name }
							.labelStyle(.iconOnly)
							.disabled(newName == name)
					}
					.buttonStyle(.borderless)
				}
			}
			Section(header: Text("Favorites")) {
				List {
					ForEach(favorites) { f in
						NavigationLink(value: f) {
							Text(f.name)
						}
					}
					.onMove{ from, to in g.move(fromOffsets: from, toOffset: to) }
					.onDelete{ indexSet in g.onDelete(deleteOffsets: indexSet) }
				}
			}
		}
		.navigationTitle("Group Details")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			EditButton()
		}
		.onChange(of: fp.timestamp, initial: true, updateFromProfile)
	}

	func updateFromProfile() {
		name = g.name
		newName = name
		favorites = g.favorites
	}

	func updateTag() {
		if (newName != name && !newName.isEmpty) {
			fp.renameGroup(g, to: newName)
		}
	}

	func addFavorite() {
		let f = if g === fp.allGroup {
			fp.newFavorite(text: "This is a sample favorite.")
		} else {
			fp.newFavorite(text: "This is a sample favorite.", tags: [g.name])
		}
		path.append(f)
	}
}
