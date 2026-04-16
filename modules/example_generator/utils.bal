import ballerina/http;
import ballerina/os;

configurable string exampleGenModel = "claude-sonnet-4-6";
configurable int exampleGenMaxTokens = 8192;

function isAIServiceInitialized() returns boolean {
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    return apiKey is string && apiKey.length() > 0;
}

function initAIService() returns error? {
    if isAIServiceInitialized() {
        return;
    }
    return error("ANTHROPIC_API_KEY environment variable not set");
}

function callAI(string prompt) returns string|error {
    string? apiKey = os:getEnv("ANTHROPIC_API_KEY");
    if apiKey is () || apiKey.length() == 0 {
        return error("ANTHROPIC_API_KEY environment variable not set");
    }

    http:Client anthropicClient = check new ("https://api.anthropic.com", {
        timeout: 1000
    });

    map<json> bodyMap = {
        "model": exampleGenModel,
        "max_tokens": exampleGenMaxTokens,
        "temperature": 0.0d,
        "messages": [
            {
                "role": "user",
                "content": prompt
            }
        ]
    };

    map<string> headers = {
        "Content-Type": "application/json",
        "x-api-key": apiKey,
        "anthropic-version": "2023-06-01"
    };

    http:Response response = check anthropicClient->post("/v1/messages", bodyMap, headers);
    if response.statusCode != 200 {
        string|error responseText = response.getTextPayload();
        if responseText is string {
            return error(string `Anthropic API error: ${response.statusCode} - ${responseText}`);
        }
        return error(string `Anthropic API error: ${response.statusCode}`);
    }

    json responseBody = check response.getJsonPayload();
    json|error contentArray = responseBody.content;
    if contentArray is json && contentArray is json[] {
        foreach json block in <json[]>contentArray {
            json|error blockType = block.'type;
            json|error textField = block.text;
            if blockType is json && blockType.toString() == "text" && textField is json {
                string|error castResult = textField.ensureType(string);
                return castResult is string ? castResult : textField.toString();
            }
        }
    }

    return error("No text block found in Anthropic response");
}
