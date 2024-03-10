//
//  ContentView.swift
//  InversityF1Strategy
//
//  Created by Jack Turner on 02/03/2024.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var teamRadio = TeamRadio()
    @State private var audioPlayer: AVPlayer?
    
    var body: some View {
        NavigationStack {
            List(teamRadio.allCommunications) { radio in
                HStack {
                    NavigationLink {
                        RadioCommunicationView(radio: radio)
                    } label: {
                        AsyncImage(url: radio.driverPhoto)
                        HStack {
                            VStack(alignment: .leading) {
                                Text(radio.driverName.capitalized)
                                    .font(.headline)
                                    .fontWeight(.heavy)
                                HStack {
                                    Button(action: {
                                        teamRadio.playAudio(from: radio.recordingURL)
                                    }) {
                                        Image(systemName: "play.circle")
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    Text(radio.date)
                                }
                            }
                        }
                    }
                }
            }
            .task {
                await teamRadio.fetchDriverPhotos()
                await teamRadio.loadSessionCommunications()
            }
            .onReceive(teamRadio.apiRequestTimer, perform: { _ in
                Task {
                    await teamRadio.updateDriverRadio()
                }
            })
            .navigationTitle("Latest Radio")
        }
    }
}

#Preview {
    ContentView()
}

