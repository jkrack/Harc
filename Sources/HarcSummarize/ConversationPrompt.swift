import Foundation

public enum ConversationPrompt {
    public static let systemPrompt = """
    You answer questions using only the local Harc context provided by the user.
    If the context does not contain enough evidence, say what is missing.
    Be concise, factual, and cite source titles inline when useful.
    """

    public static let maxOutputTokens = 900

    public static func build(question: String, contextMarkdown: String) -> String {
        """
        Answer this question from the local Harc context.

        Question:
        \(question)

        Local context:
        <<<
        \(contextMarkdown)
        >>>

        Rules:
        - Use only the local context above.
        - Prefer direct evidence over summaries.
        - If the answer is uncertain, say so and name the missing evidence.
        - Keep the answer readable in 1-5 short paragraphs.
        """
    }
}
