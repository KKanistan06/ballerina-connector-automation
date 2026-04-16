public function initExampleGenerator() returns error? {
    return initAIService();
}

public function generateUseCaseAndFunctions(ConnectorDetails details, string[] usedFunctions) returns json|error {
    string prompt = getUsecasePrompt(details, usedFunctions);

    if !isAIServiceInitialized() {
        return error("AI model not initialized. Please call initExampleGenerator() first.");
    }

    string result = check callAI(prompt);

    return result.fromJsonString();
}

public function generateExampleCode(ConnectorDetails details, string useCase, string targetedContext) returns string|error {
    string prompt = getExampleCodegenerationPrompt(details, useCase, targetedContext);

    if !isAIServiceInitialized() {
        return error("AI model not initialized. Please call initExampleGenerator() first.");
    }

    string result = check callAI(prompt);

    return result;
}

public function generateExampleName(string useCase) returns string|error {
    string prompt = getExampleNamePrompt(useCase);

    if !isAIServiceInitialized() {
        return error("AI model not initialized. Please call initExampleGenerator() first.");
    }

    string|error result = callAI(prompt);
    if result is error {
        return error("Failed to generate example name", result);
    }

    return result == "" ? "example-1" : result;
}
