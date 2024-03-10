//
//  RadioCommunicationView.swift
//  InversityF1Strategy
//
//  Created by Jack Turner on 08/03/2024.
//

import SwiftUI

struct RadioCommunicationView: View {
    var radio: TeamRadio.DriverCommunication
    
    var body: some View {
        ScrollView {
            AsyncImage(url: radio.unscaledDriverPhoto, scale: 3)
                .position(CGPoint(x: 200, y: 80))
                .ignoresSafeArea()
            Group {
                VStack(alignment: .leading) {
                    Text("Radio Classification: \(radio.feeling) about \(radio.aspect)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical)
                    Text("Predicted Accuracy: \(radio.calculatedScore.formatted())")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(radio.scoreMessage)
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Radio Message:")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(radio.transcript ?? "Transcript Unavailable")
                        .font(.title3)
                        .fontWeight(.bold)
                }
                .padding()
                HStack {
                    Text("Similiar Communications:")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                ForEach(radio.similarCommunications) { radio in
                    Text(radio.transcript ?? "Transcript not found")
                        .padding(.top, 7)
                    if let communicationScore = radio.score {
                        Text("Calculated Accuracy: \(communicationScore.formatted())")
                            .padding()
                    } else {
                        Text("Accuracy: N/A")
                            .padding()
                    }
                    Divider()
                }
                .padding(.horizontal)
            }
            .offset(CGSize(width: 0, height: -60))
        }
    }
}
