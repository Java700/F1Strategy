//
//  TeamRadio.swift
//  InversityF1Strategy
//
//  Created by Jack Turner on 02/03/2024.
//

import Foundation
import Speech
import AudioKit


@Observable
class TeamRadio {
    static let apiAddress = "https//api.openf1.org/v1/team_radio?session_key=9158"
    var allCommunications: [DriverCommunication]
    var driverPhotos: [DriverPhoto]
    let apiRequestTimer = Timer.publish(every: 20, tolerance: 3, on: .main, in: .common).autoconnect()
    private var audioPlayer: AVPlayer?
    let openAIClass = OpenAIConnector()

    
    init() {
        self.allCommunications = []
        self.driverPhotos = []
    }
    
    struct DriverCommunication: Identifiable, Codable, Equatable {
        static func == (lhs: TeamRadio.DriverCommunication, rhs: TeamRadio.DriverCommunication) -> Bool {
            lhs.driverNumber == rhs.driverNumber && lhs.date == rhs.date
        }
        
        let id: UUID
        let date: String
        let driverNumber: Int
        let meetingKey: Int
        let recordingURL: URL
        let sessionKey: Int
        var driverPhoto: URL?
        var driverName: String
        var transcript: String?
        var transcriptClassification: Classification?
        var similarCommunications: [DriverCommunication]
        var score: Float?
        
        var unscaledDriverPhoto: URL? {
               guard let photoURL = driverPhoto else { return nil }
               let urlString = photoURL.absoluteString
               if let range = urlString.range(of: ".png") {
                   let truncatedURLString = urlString[..<range.upperBound]
                   return URL(string: String(truncatedURLString))
               }
               return nil
           }
        
        var calculatedScore: Double {
            var total = 0.0
            for communication in similarCommunications {
                total += Double(communication.score ?? 1)
            }
            return ((total/(Double(similarCommunications.count)))*1000).rounded() / 1000
        }
        
        var scoreMessage: String {
            if 0.75 < calculatedScore && calculatedScore < 1 {
                return "In the past, similar communications to this one were strongly correlated with the short term performance of this driver"
            } else if 0.5 < calculatedScore && calculatedScore <= 0.75 {
                return "In the past, similar communications to this were only correlated with the driver's short term performance 2/3 of the time"
            } else if 0.25 < calculatedScore && calculatedScore <= 0.5 {
                return "In the past, similar communications to this were only correlated with the driver's short term performance 1/3 of the time"
            } else if 0 < calculatedScore && calculatedScore <= 0.25 {
                return "In the past, similar communications to this were rarely correlated with the driver's short term perforance"
            }
            return ""
        }
        
        var feeling: String {
            switch transcriptClassification?.radioType {
            case .negative:
                return "Negative"
            case .positive:
                return "Positive"
            case .neutral:
                return "Neutral"
            case .none:
                return ""
            }
        }
        
        var aspect: String {
            switch transcriptClassification?.raceAspect {
            case .tyres:
                return "tyres"
            case .strategy:
                return "strategy"
            case .car:
                return "car"
            case .neutral:
                return ""
            case nil:
                return ""
            }
        }
        
        enum CodingKeys: String, CodingKey {
            case date
            case driverNumber = "driver_number"
            case meetingKey = "meeting_key"
            case recordingURL = "recording_url"
            case sessionKey = "session_key"
        }
        
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let dateString = try container.decode(String.self, forKey: .date)
            
            let start = dateString.index(dateString.startIndex, offsetBy: 11)
            let end = dateString.index(dateString.startIndex, offsetBy: 19)
            date = String(dateString[start..<end])
            
            let localDriverNumber = try container.decode(Int.self, forKey: .driverNumber)
            driverNumber = localDriverNumber
            meetingKey = try container.decode(Int.self, forKey: .meetingKey)
            recordingURL = try container.decode(URL.self, forKey: .recordingURL)
            sessionKey = try container.decode(Int.self, forKey: .sessionKey)
            id = UUID()

            
            // Retrieve driverPhotos array from decoder's userInfo dictionary
            guard let driverPhotos = decoder.userInfo[.driverPhotos] as? [DriverPhoto] else {
                fatalError("Missing driverPhotos array in decoder's userInfo")
            }
            
            if let driverPhoto = driverPhotos.first(where: { $0.driverNumber == localDriverNumber }) {
                self.driverName = driverPhoto.driverName
                
                if let headshotURL = driverPhoto.headshotURL {
                    self.driverPhoto = headshotURL
                } else {
                    self.driverPhoto = nil
                }
            } else {
                self.driverName = "Name Not Found"
            }
            
            self.transcript = nil
            self.transcriptClassification = nil
            self.score = nil
            self.similarCommunications = []
        }
        
        struct Classification {
            let radioType: RadioType
            let raceAspect: RaceAspect
        }
        
        enum RadioType {
            case positive
            case negative
            case neutral
        }
        
        enum RaceAspect {
            case tyres
            case strategy
            case car
            case neutral
        }
    }

    
    struct DriverPhoto: Codable {
        let driverName: String
        let driverNumber: Int
        let headshotURL: URL?
        
        enum CodingKeys: String, CodingKey {
            case driverName = "full_name"
            case driverNumber = "driver_number"
            case headshotURL = "headshot_url"
        }
    }
    
    func playAudio(from url: URL?) {
        guard let url = url else { return }
        
        audioPlayer?.pause()
        
        audioPlayer = AVPlayer(url: url)
        
        audioPlayer?.play()
    }
    
    //MARK: API Communications
    
    
    func fetchDriverPhotos() async {
        // 9158
        guard let photosURL = URL(string: "https://api.openf1.org/v1/drivers?session_key=latest") else {
            print("Invalid URL")
            return
        }
        
        do {
            let (response, _) = try await URLSession.shared.data(from: photosURL)
            
            let decodedResponse = try JSONDecoder().decode([DriverPhoto].self, from: response)
            self.driverPhotos = decodedResponse
        } catch {
            print("Unable to decode photos")
            print(error.localizedDescription)
        }
    }
    
    func loadSessionCommunications() async {
        guard let sessionURL = URL(string: "https://api.openf1.org/v1/team_radio?session_key=latest") else {
            print("Invalid URL")
            return
        }
        
        do {
            let (response, _) = try await URLSession.shared.data(from: sessionURL)
            
            let decoder = JSONDecoder()
            // Why does this not work? Why do I have to make it a string?
            decoder.dateDecodingStrategy = .iso8601
            decoder.userInfo[.driverPhotos] = self.driverPhotos
            
            let decodedResponse = try decoder.decode([DriverCommunication].self, from: response)
            
            allCommunications = decodedResponse
            
            allCommunications.reverse()
        } catch {
            print("Decoding error: \(error)")
        }
    }

    func updateDriverRadio() async {
        guard let sessionURL = URL(string: TeamRadio.apiAddress) else {
            print("Invalid URL")
            return
        }
        
        do {
            let (response, _) = try await URLSession.shared.data(from: sessionURL)
            let decoder = JSONDecoder()
            
            let decodedResponse = try decoder.decode([DriverCommunication].self, from: response)
            if decodedResponse.count > self.allCommunications.count {
                let newCommunications = decodedResponse.filter { !allCommunications.contains($0) }
                
                for var communication in newCommunications {
                    // MARK: Get the transcript of the communication
                    self.transcribeAudioFromURL(audioURL: communication.recordingURL) { transcribedText in
                        communication.transcript = transcribedText
                    }
                    
                    // MARK: Now classify the transcript using AI
                    
                    let prompt = "This is a transcription of an F1 drivers team radio message. Put it into one of the following categories: Negative about car, Negative about strategy, Negative about tyres, Positive about car, Positive about strategy, Positive about tyres, Encoded strategy, or Neutral. Encoded strategy refers to when a driver says Plan A/ Plan B etc... Include only the name of the category in your response and no other semantics. Here is the transcribed audio:"
                    let classificationString = openAIClass.processPrompt(prompt: prompt)!
                    communication.transcriptClassification = self.convertStringToClassification(classificationString)
                    
                    //MARK: Now that you have got the transcript for the communication and type of transcript calculate the score
                    
                    // First the communication file for that driver needs to opened.
                    let fileName = communication.driverName + "TeamRadio.txt"
                    
                    if let filepath = Bundle.main.path(forResource: fileName, ofType: "txt") {
                        do {
                            let contents = try String(contentsOfFile: filepath)
                            let previousCommunications = contents.components(separatedBy: "\n")
                            
                            let decoder = JSONDecoder()
                            decoder.dateDecodingStrategy = .iso8601
                            decoder.userInfo[.driverPhotos] = self.driverPhotos
                            
                            var decodedCommunications = [DriverCommunication]()
                            
                            for jsonString in previousCommunications {
                                if let jsonData = jsonString.data(using: .utf8) {
                                    do {
                                        let decodedStruct = try JSONDecoder().decode(DriverCommunication.self, from: jsonData)
                                        decodedCommunications.append(decodedStruct)
                                    } catch {
                                        print("Error decoding JSON string: \(error)")
                                    }
                                }
                            }
                            
                            let sameClassPreviousCommunications = decodedCommunications.filter { pastCommunication in
                                pastCommunication.transcriptClassification?.radioType == communication.transcriptClassification?.radioType && pastCommunication.transcriptClassification?.raceAspect == communication.transcriptClassification?.raceAspect
                            }
                            
                            let previousSimilarCommunicationScores : [Float] = sameClassPreviousCommunications.map { pastCommunication in
                                pastCommunication.score ?? 1
                            }
                            
                            let sumOfScores = previousSimilarCommunicationScores.reduce(0, +)
                            let currentScore = sumOfScores / Float(previousSimilarCommunicationScores.count)
                            
                            communication.score = currentScore
                            communication.similarCommunications = sameClassPreviousCommunications
                            
                            allCommunications = decodedCommunications + allCommunications
                            
                        } catch {
                            print("Contents of \(fileName) could not be opened")
                        }
                    } else {
                        print("File \(fileName) could not be located")
                    }
                }
            }
            
        } catch {
            print("Decoding error: \(error)")
        }
    }
    
    func transcribeAudioFromURL(audioURL: URL, completion: @escaping (String?) -> Void) {
        // 1. Request speech recognition permission. You have to do this even if you are not going to use the device's microphone
        SFSpeechRecognizer.requestAuthorization { authStatus in
            guard authStatus == .authorized else {
                print("Speech recognition authorization denied.")
                completion(nil)
                return
            }
            
            // 2. Fetch the audio file from the remote URL
            let task = URLSession.shared.downloadTask(with: audioURL) { localURL, response, error in
                guard let localURL = localURL else {
                    print(error?.localizedDescription ?? "Unknown error")
                    completion(nil)
                    return
                }
                
                // 3. Transcribe the audio file
                let recognizer = SFSpeechRecognizer()
                let request = SFSpeechURLRecognitionRequest(url: localURL)
                
                recognizer?.recognitionTask(with: request) { result, error in
                    guard let result = result else {
                        print(error?.localizedDescription ?? "Unknown error")
                        completion(nil)
                        return
                    }
                    
                    if result.isFinal {
                        completion(result.bestTranscription.formattedString)
                    }
                }
            }
            
            task.resume()
        }
    }
    
    func convertStringToClassification(_ string: String) -> TeamRadio.DriverCommunication.Classification {
        if string == "Encoded strategy" {
            return TeamRadio.DriverCommunication.Classification(radioType: .neutral, raceAspect: .strategy)
        } else if string == "Neutral" {
            return TeamRadio.DriverCommunication.Classification(radioType: .neutral, raceAspect: .neutral)
        } else {
            let components = string.components(separatedBy: " about ")
            
            guard components.count == 2 else {
                fatalError("Invalid string format")
            }
            
            let radioType: TeamRadio.DriverCommunication.RadioType
            let raceAspect: TeamRadio.DriverCommunication.RaceAspect
            
            switch components[0] {
            case "Negative":
                radioType = .negative
            case "Positive":
                radioType = .positive
            default:
                fatalError("Invalid radio type")
            }
            
            switch components[1] {
            case "car":
                raceAspect = .car
            case "strategy":
                raceAspect = .strategy
            case "tyres":
                raceAspect = .tyres
            default:
                fatalError("Invalid race aspect")
            }
            
            return TeamRadio.DriverCommunication.Classification(radioType: radioType, raceAspect: raceAspect)
        }
    }
}

extension CodingUserInfoKey {
    static let driverPhotos = CodingUserInfoKey(rawValue: "driverPhotos")!
}
