//
//  ContentView.swift
//  local-coder
//
//

import SwiftUI

struct ContentView: View {
    @State private var message = ""
    @State private var messages: [String] = []

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "global")
                .imageScale(.large)
                .foregroundStyle(.tint)
            
            
            ScrollView {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(messages.indices, id: \.self) { index in
                        Text(messages[index])
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(.white)
                            .background(.blue, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .frame(maxWidth: 280, alignment: .trailing)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 360, height: 220)

            HStack(spacing: 8) {
                TextField("Message", text: $message)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .onSubmit(sendMessage)

                Button {
                    messages.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .frame(maxWidth: 360)
        }
        .padding()
    }
    
    private func clearAllMessages() {
        messages.removeAll()
    }

    private func sendMessage() {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedMessage.isEmpty else {
            return
        }

        messages.append(trimmedMessage)
        print(trimmedMessage)
        message = ""
    }
}

#Preview {
    ContentView()
}
