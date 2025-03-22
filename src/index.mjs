export async function lambdaHandler(event, context) {
    return { statusCode: 200, body: JSON.stringify({ message: 'Helo world!' }) };
}
