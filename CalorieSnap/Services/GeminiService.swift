import Foundation
import UIKit

/// The structured result we ask Gemini to return.
struct NutritionAnalysis: Codable {
    struct Item: Codable {
        var name: String
        var portion: String
        var grams: Double
        var calories: Double
        var proteinG: Double
        var carbsG: Double
        var fatG: Double
        var fiberG: Double?
        var sugarG: Double?
        var sodiumMg: Double?
        var confidence: Double?

        var asFoodItem: FoodItem {
            FoodItem(name: name, portion: portion, grams: grams, calories: calories,
                     protein: proteinG, carbs: carbsG, fat: fatG,
                     fiber: fiberG ?? 0, sugar: sugarG ?? 0, sodiumMg: sodiumMg ?? 0,
                     confidence: confidence)
        }
    }

    var mealName: String
    var items: [Item]
    var notes: String?
}

enum GeminiError: LocalizedError {
    case missingAPIKey
    case badImage
    case http(Int, String)
    case blocked(String)
    case emptyResponse
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your Gemini API key in Settings first."
        case .badImage: "Couldn't process that photo. Try another one."
        case .http(let code, let message): "Gemini returned an error (\(code)): \(message)"
        case .blocked(let reason): "Gemini didn't return a result (\(reason)). Try a different photo."
        case .emptyResponse: "Gemini returned an empty response. Please try again."
        case .decoding(let detail): "Couldn't read Gemini's response: \(detail)"
        }
    }
}

struct GeminiService {
    let apiKey: String
    let model: String
    /// Tried after the primary model keeps failing with overload/rate-limit errors. Empty = no fallback.
    var fallbackModel: String = ""
    /// Called with a short status message while retrying (e.g. "Gemini is busy, retrying…").
    var onStatus: (@MainActor (String) -> Void)? = nil

    /// HTTP codes that mean "busy / try again", not "your request is wrong".
    private static let retryableStatus: Set<Int> = [429, 500, 502, 503, 504]
    private static let attemptsPerModel = 3

    /// Tries the primary model with exponential backoff (≈1s, 2s + jitter), then the fallback model.
    private func sendWithRetry(bodyData: Data) async throws -> Data {
        var models = [model.trimmingCharacters(in: .whitespaces)]
        let fallback = fallbackModel.trimmingCharacters(in: .whitespaces)
        if !fallback.isEmpty && fallback != models[0] { models.append(fallback) }

        var lastError: Error = GeminiError.emptyResponse
        for (modelIndex, currentModel) in models.enumerated() {
            for attempt in 0..<Self.attemptsPerModel {
                do {
                    return try await post(bodyData: bodyData, model: currentModel)
                } catch let error as GeminiError {
                    guard case .http(let code, _) = error, Self.retryableStatus.contains(code) else { throw error }
                    lastError = error
                } catch let error as URLError where [.timedOut, .networkConnectionLost].contains(error.code) {
                    lastError = error
                }

                let isLastAttempt = attempt == Self.attemptsPerModel - 1
                if isLastAttempt {
                    if modelIndex + 1 < models.count {
                        await onStatus?("Gemini is busy — trying \(models[modelIndex + 1])…")
                    }
                } else {
                    await onStatus?("Gemini is busy — retrying (\(attempt + 2)/\(Self.attemptsPerModel))…")
                    let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...0.5)
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        throw lastError
    }

    private func post(bodyData: Data, model: String) async throws -> Data {
        let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(escapedModel):generateContent") else {
            throw GeminiError.http(0, "Invalid model name")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GeminiError.http(status, message)
        }
        return data
    }

    private static let prompt = """
    You are an expert registered dietitian analyzing a photo of food someone is about to eat.

    1. Identify every distinct food and drink that is visible. Split combined dishes into sensible \
    components when that improves accuracy (e.g. "grilled chicken breast", "white rice", "steamed broccoli"), \
    but keep obvious single dishes (e.g. "pepperoni pizza slice") as one item.
    2. Estimate the portion actually shown, using visual cues for scale (plate ~26 cm, fork ~19 cm, \
    standard cans, cups, hands). Express it both as a human-readable portion and in grams.
    3. Estimate nutrition for that portion using typical USDA-style values, accounting for visible \
    cooking oil, sauces, dressings, cheese and toppings.
    4. confidence is 0-1: how sure you are about the identification and portion combined.
    5. mealName is a short, friendly title for the whole meal (max 5 words).
    6. notes: one or two short sentences on key assumptions (e.g. "Assumed whole milk"). Empty if none.
    If there is no food or drink in the image, return an empty items array and explain in notes.
    """

    private static let responseSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "mealName": ["type": "STRING"],
            "notes": ["type": "STRING"],
            "items": [
                "type": "ARRAY",
                "items": [
                    "type": "OBJECT",
                    "properties": [
                        "name": ["type": "STRING"],
                        "portion": ["type": "STRING", "description": "e.g. '1 cup', '2 slices', '1 medium'"],
                        "grams": ["type": "NUMBER"],
                        "calories": ["type": "NUMBER", "description": "kcal for this portion"],
                        "proteinG": ["type": "NUMBER"],
                        "carbsG": ["type": "NUMBER"],
                        "fatG": ["type": "NUMBER"],
                        "fiberG": ["type": "NUMBER"],
                        "sugarG": ["type": "NUMBER"],
                        "sodiumMg": ["type": "NUMBER"],
                        "confidence": ["type": "NUMBER"]
                    ],
                    "required": ["name", "portion", "grams", "calories", "proteinG", "carbsG", "fatG",
                                 "fiberG", "sugarG", "sodiumMg", "confidence"],
                    "propertyOrdering": ["name", "portion", "grams", "calories", "proteinG", "carbsG", "fatG",
                                         "fiberG", "sugarG", "sodiumMg", "confidence"]
                ]
            ]
        ],
        "required": ["mealName", "items", "notes"],
        "propertyOrdering": ["mealName", "items", "notes"]
    ]

    func analyze(image: UIImage, hint: String?) async throws -> NutritionAnalysis {
        guard let jpeg = image.resized(maxDimension: 1280).jpegData(compressionQuality: 0.75) else {
            throw GeminiError.badImage
        }

        var text = Self.prompt
        if let hint, !hint.trimmingCharacters(in: .whitespaces).isEmpty {
            text += "\n\nExtra context from the user (trust this over your visual guess): \(hint)"
        }

        let body: [String: Any] = [
            "contents": [[
                "role": "user",
                "parts": [
                    ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["text": text]
                ]
            ]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": Self.responseSchema
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let data = try await sendWithRetry(bodyData: bodyData)

        let envelope: GenerateContentResponse
        do {
            envelope = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        } catch {
            throw GeminiError.decoding(error.localizedDescription)
        }

        if let reason = envelope.promptFeedback?.blockReason {
            throw GeminiError.blocked(reason)
        }
        guard let candidate = envelope.candidates?.first else { throw GeminiError.emptyResponse }

        // Newer models may return "thought" parts; only use the answer text.
        let json = (candidate.content?.parts ?? [])
            .filter { $0.thought != true }
            .compactMap(\.text)
            .joined()
        guard !json.isEmpty else {
            if let reason = candidate.finishReason, reason != "STOP" { throw GeminiError.blocked(reason) }
            throw GeminiError.emptyResponse
        }

        do {
            return try JSONDecoder().decode(NutritionAnalysis.self, from: Data(json.utf8))
        } catch {
            throw GeminiError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Response envelopes

private struct GenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
                let thought: Bool?
            }
            let parts: [Part]?
        }
        let content: Content?
        let finishReason: String?
    }
    struct PromptFeedback: Decodable { let blockReason: String? }

    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}

// MARK: - Image helpers

extension UIImage {
    /// Downscales so the longest side is at most `maxDimension` points (keeps uploads small and fast).
    func resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Compact JPEG for storing alongside a meal.
    var storageJPEG: Data? { resized(maxDimension: 800).jpegData(compressionQuality: 0.7) }
}
