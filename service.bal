import ballerina/http;
import ballerina/mime;
import ballerina/time;
import ballerina/uuid;
import ballerinax/openai.chat;

// Configure your OpenAI API key
configurable string openaiApiKey = ?;

// Create OpenAI chat client
final chat:Client chatClient = check new ({
    auth: {
        token: openaiApiKey
    }
});

// In-memory storage for CSV data
map<CSVData> csvStore = {};

# Represents uploaded CSV data
#
# + id - Unique identifier for the CSV file
# + filename - Name of the uploaded file
# + headers - Column headers from the CSV
# + rows - Data rows from the CSV
# + rowCount - Total number of rows
# + columnCount - Total number of columns
# + uploadedAt - Timestamp of upload
type CSVData record {|
    string id;
    string filename;
    string[] headers;
    string[][] rows;
    int rowCount;
    int columnCount;
    string uploadedAt;
|};

# Chat request structure
#
# + fileId - ID of the CSV file
# + message - User message
# + context - Optional conversation context
type ChatRequest record {|
    string fileId;
    string message;
    string? context?;
|};

// CORS configuration - UPDATE with your actual frontend domain
@http:ServiceConfig {
    cors: {
        allowOrigins: [
            "https://ballerina-llm-csv-an-y9ok.bolt.host/", // Replace with your frontend production URL
            "http://localhost:8080" // Alternative local dev
        ],
        allowMethods: ["GET", "POST", "DELETE", "OPTIONS"],
        allowHeaders: ["Content-Type", "Authorization"],
        allowCredentials: false
    }
}
service /csv\-chat on new http:Listener(9090) {

    # Health check endpoint
    #
    # + return - Health status
    resource function get health() returns json {
        time:Utc currentTime = time:utcNow();
        string timeString = time:utcToString(currentTime);
        return {
            status: "healthy",
            "service": "CSV Analytics Chatbot",
            timestamp: timeString,
            version: "1.0.0"
        };
    }

    # Upload a CSV file for analysis
    #
    # + req - HTTP request with file
    # + return - Upload result or error
    resource function post upload(http:Request req) returns json|http:BadRequest|http:InternalServerError {
        
        var bodyParts = req.getBodyParts();
        if bodyParts is error {
            return <http:BadRequest>{body: "Invalid request format"};
        }

        mime:Entity? csvPart = ();
        foreach var part in bodyParts {
            mime:ContentDisposition disposition = part.getContentDisposition();
            string? nameField = disposition.name;
            if nameField == "file" {
                csvPart = part;
                break;
            }
        }

        if csvPart is () {
            return <http:BadRequest>{body: "No file uploaded"};
        }

        byte[]|error csvBytes = csvPart.getByteArray();
        if csvBytes is error {
            return <http:BadRequest>{body: "Failed to read file"};
        }

        string|error csvContent = 'string:fromBytes(csvBytes);
        if csvContent is error {
            return <http:BadRequest>{body: "Invalid CSV format"};
        }

        // Parse CSV
        string[] lines = re `\r?\n`.split(csvContent.trim());
        if lines.length() < 2 {
            return <http:BadRequest>{body: "CSV must have headers and at least one row"};
        }

        string[] headers = re `,`.split(lines[0]);
        string[][] rows = [];
        
        foreach int i in 1 ..< lines.length() {
            if lines[i].trim().length() > 0 {
                rows.push(re `,`.split(lines[i]));
            }
        }

        string fileId = uuid:createType1AsString();
        time:Utc currentTime = time:utcNow();
        string timeString = time:utcToString(currentTime);
        
        mime:ContentDisposition disposition = csvPart.getContentDisposition();
        string filename = "unknown.csv";
        string? fileNameField = disposition.fileName;
        if fileNameField is string {
            filename = fileNameField;
        }
        
        CSVData csvData = {
            id: fileId,
            filename: filename,
            headers: headers,
            rows: rows,
            rowCount: rows.length(),
            columnCount: headers.length(),
            uploadedAt: timeString
        };
        
        lock {
            csvStore[fileId] = csvData;
        }

        return {
            message: "CSV uploaded successfully",
            fileId: fileId,
            filename: csvData.filename,
            rowCount: csvData.rowCount,
            columnCount: csvData.columnCount,
            headers: csvData.headers
        };
    }

    # Ask a question about CSV data
    #
    # + fileId - ID of the CSV file
    # + question - Question to ask
    # + return - Analysis result or error
    resource function get query(string fileId, string question) 
            returns json|http:NotFound|http:InternalServerError {
        
        CSVData? csvData = ();
        lock {
            if !csvStore.hasKey(fileId) {
                return <http:NotFound>{body: "CSV file not found"};
            }
            csvData = csvStore.get(fileId);
        }

        if csvData is () {
            return <http:NotFound>{body: "CSV file not found"};
        }
        
        string headerStr = string:'join(", ", ...csvData.headers);
        string sampleData = getSampleRows(csvData, 5);
        
        string prompt = string `You are a data analyst. Analyze this CSV data and answer the question.

File: ${csvData.filename}
Rows: ${csvData.rowCount}
Columns: ${csvData.columnCount}
Headers: ${headerStr}

Sample Data (first 5 rows):
${sampleData}

Question: ${question}

Provide a clear answer with specific insights from the data. If calculations are needed, show them. 
Suggest a visualization if it would help understand the answer better.
Be specific and reference actual values from the data when possible.

Return your response as a JSON object with this structure:
{
    "question": "${question}",
    "answer": "your detailed answer here",
    "calculations": null or calculation details,
    "insights": ["insight 1", "insight 2"],
    "visualization": null or {
        "chartType": "bar/line/pie/scatter",
        "title": "chart title",
        "xAxis": "column name",
        "yAxis": "column name",
        "description": "chart description",
        "data": {}
    }
}`;

        chat:CreateChatCompletionRequest chatRequest = {
            model: "gpt-4o",
            messages: [
                {
                    "role": "user",
                    "content": prompt
                }
            ]
        };

        chat:CreateChatCompletionResponse|error result = chatClient->/chat/completions.post(chatRequest);

        if result is chat:CreateChatCompletionResponse {
            string? content = result.choices[0].message?.content;
            if content is string {
                return {
                    question: question,
                    answer: content,
                    fileInfo: {
                        filename: csvData.filename,
                        rowCount: csvData.rowCount,
                        columnCount: csvData.columnCount
                    }
                };
            }
            return <http:InternalServerError>{body: "No response generated"};
        }
        return <http:InternalServerError>{
            body: string `Failed to analyze data: ${result.message()}`
        };
    }

    # Get automated insights
    #
    # + fileId - ID of the CSV file
    # + return - Data insights or error
    resource function get insights(string fileId) 
            returns json|http:NotFound|http:InternalServerError {
        
        CSVData? csvData = ();
        lock {
            if !csvStore.hasKey(fileId) {
                return <http:NotFound>{body: "CSV file not found"};
            }
            csvData = csvStore.get(fileId);
        }

        if csvData is () {
            return <http:NotFound>{body: "CSV file not found"};
        }
        
        string headerStr = string:'join(", ", ...csvData.headers);
        string allData = getAllRows(csvData);
        
        string prompt = string `Analyze this CSV data comprehensively and provide insights:

File: ${csvData.filename}
Rows: ${csvData.rowCount}
Columns: ${csvData.columnCount}
Headers: ${headerStr}

Full Data:
${allData}

Identify:
1. A brief summary of what this data represents
2. Key findings and patterns in the data
3. Insights about each important column (trends, outliers, distributions)
4. Actionable recommendations based on the data

Be specific and use actual values from the dataset.

Return your response as a JSON object with this structure:
{
    "summary": "brief summary",
    "keyFindings": ["finding 1", "finding 2"],
    "columnInsights": [
        {"column": "column name", "insight": "insight about this column"}
    ],
    "recommendations": ["recommendation 1", "recommendation 2"]
}`;

        chat:CreateChatCompletionRequest chatRequest = {
            model: "gpt-4o",
            messages: [
                {
                    "role": "user",
                    "content": prompt
                }
            ]
        };

        chat:CreateChatCompletionResponse|error insights = chatClient->/chat/completions.post(chatRequest);

        if insights is chat:CreateChatCompletionResponse {
            string? content = insights.choices[0].message?.content;
            if content is string {
                return {
                    insights: content,
                    fileInfo: {
                        filename: csvData.filename,
                        rowCount: csvData.rowCount,
                        columnCount: csvData.columnCount
                    }
                };
            }
            return <http:InternalServerError>{body: "No insights generated"};
        }
        return <http:InternalServerError>{
            body: string `Failed to generate insights: ${insights.message()}`
        };
    }

    # Get visualization recommendations
    #
    # + fileId - ID of the CSV file
    # + analysisGoal - Optional analysis goal
    # + return - Visualization suggestions or error
    resource function get visualize(string fileId, string? analysisGoal = ()) 
            returns json|http:NotFound|http:InternalServerError {
        
        CSVData? csvData = ();
        lock {
            if !csvStore.hasKey(fileId) {
                return <http:NotFound>{body: "CSV file not found"};
            }
            csvData = csvStore.get(fileId);
        }

        if csvData is () {
            return <http:NotFound>{body: "CSV file not found"};
        }
        
        string headerStr = string:'join(", ", ...csvData.headers);
        string sampleData = getSampleRows(csvData, 10);
        
        string goal = "general analysis";
        if analysisGoal is string {
            goal = analysisGoal;
        }

        string prompt = string `Suggest 2-3 effective visualizations for this data with goal: ${goal}

File: ${csvData.filename}
Headers: ${headerStr}
Sample Data:
${sampleData}

For each visualization, specify:
- Chart type (bar, line, pie, scatter, or table)
- Title and description
- Which columns to use for x and y axes
- Sample data formatted for the chart

Make suggestions that will provide real insights from this specific data.

Return your response as a JSON array with this structure:
[
    {
        "chartType": "bar/line/pie/scatter/table",
        "title": "chart title",
        "xAxis": "column name",
        "yAxis": "column name",
        "description": "why this visualization is useful",
        "data": {}
    }
]`;

        chat:CreateChatCompletionRequest chatRequest = {
            model: "gpt-4o",
            messages: [
                {
                    "role": "user",
                    "content": prompt
                }
            ]
        };

        chat:CreateChatCompletionResponse|error suggestions = chatClient->/chat/completions.post(chatRequest);

        if suggestions is chat:CreateChatCompletionResponse {
            string? content = suggestions.choices[0].message?.content;
            if content is string {
                return {
                    visualizations: content,
                    fileInfo: {
                        filename: csvData.filename,
                        rowCount: csvData.rowCount,
                        columnCount: csvData.columnCount
                    }
                };
            }
            return <http:InternalServerError>{body: "No visualizations generated"};
        }
        return <http:InternalServerError>{
            body: string `Failed to generate visualizations: ${suggestions.message()}`
        };
    }

    # Chat with your data
    #
    # + chatReq - Chat request
    # + return - Chat response or error
    resource function post chat(ChatRequest chatReq) 
            returns json|http:NotFound|http:InternalServerError {
        
        CSVData? csvData = ();
        lock {
            if !csvStore.hasKey(chatReq.fileId) {
                return <http:NotFound>{body: "CSV file not found"};
            }
            csvData = csvStore.get(chatReq.fileId);
        }

        if csvData is () {
            return <http:NotFound>{body: "CSV file not found"};
        }
        
        string headerStr = string:'join(", ", ...csvData.headers);
        string sampleData = getSampleRows(csvData, 8);
        
        string conversationContext = "This is the start of the conversation.";
        if chatReq?.context is string {
            conversationContext = chatReq?.context ?: "";
        }

        string prompt = string `You are a helpful data analyst assistant. Help the user understand their CSV data.

CSV: ${csvData.filename}
Headers: ${headerStr}
Rows: ${csvData.rowCount}

Data Sample:
${sampleData}

Previous conversation: ${conversationContext}

User message: ${chatReq.message}

Provide a helpful response. If the user asks about the data, analyze it and provide
specific answers. Show your reasoning process. If calculations are involved, include them.

Return your response as a JSON object with this structure:
{
    "answer": "your response to the user",
    "reasoning": "your reasoning process",
    "sqlQuery": null or "SQL query if applicable",
    "data": null or relevant data
}`;

        chat:CreateChatCompletionRequest chatRequest = {
            model: "gpt-4o",
            messages: [
                {
                    "role": "user",
                    "content": prompt
                }
            ]
        };

        chat:CreateChatCompletionResponse|error response = chatClient->/chat/completions.post(chatRequest);

        if response is chat:CreateChatCompletionResponse {
            string? content = response.choices[0].message?.content;
            if content is string {
                return {
                    answer: content,
                    context: conversationContext + "\n\nUser: " + chatReq.message + "\n\nAssistant: " + content,
                    fileInfo: {
                        filename: csvData.filename,
                        rowCount: csvData.rowCount
                    }
                };
            }
            return <http:InternalServerError>{body: "No response generated"};
        }
        return <http:InternalServerError>{
            body: string `Failed to process chat: ${response.message()}`
        };
    }

    # List all uploaded CSV files
    #
    # + return - List of uploaded files
    resource function get files() returns json {
        json[] filesList = [];
        lock {
            foreach var [id, data] in csvStore.entries() {
                filesList.push({
                    id: id,
                    filename: data.filename,
                    rowCount: data.rowCount,
                    columnCount: data.columnCount,
                    headers: data.headers,
                    uploadedAt: data.uploadedAt
                });
            }
        }
        return {files: filesList};
    }

    # Delete a CSV file
    #
    # + fileId - ID of the file to delete
    # + return - Deletion result or error
    resource function delete file/[string fileId]() returns json|http:NotFound {
        
        lock {
            if !csvStore.hasKey(fileId) {
                return <http:NotFound>{body: "CSV file not found"};
            }
            _ = csvStore.remove(fileId);
        }
        return {message: "File deleted successfully", fileId: fileId};
    }
}

# Helper function to get sample rows
#
# + csvData - CSV data
# + count - Number of rows to return
# + return - Sample rows as string
isolated function getSampleRows(CSVData csvData, int count) returns string {
    string headerLine = string:'join(", ", ...csvData.headers);
    string result = headerLine + "\n";
    
    int rowsLength = csvData.rows.length();
    int maxRows = count;
    if rowsLength < count {
        maxRows = rowsLength;
    }
    
    int index = 0;
    while index < maxRows {
        string rowLine = string:'join(", ", ...csvData.rows[index]);
        result = result + rowLine + "\n";
        index = index + 1;
    }
    
    return result;
}

# Helper function to get all rows
#
# + csvData - CSV data
# + return - All rows as string
isolated function getAllRows(CSVData csvData) returns string {
    if csvData.rowCount > 100 {
        string sample = getSampleRows(csvData, 100);
        return sample + "\n... (showing first 100 rows)";
    }
    return getSampleRows(csvData, csvData.rowCount);
}

