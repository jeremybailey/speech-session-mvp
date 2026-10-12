"""Classify diagnostic gateway errors without exposing response text or retrying."""
def error_message(response):
    if not isinstance(response, dict):
        return 'Benchmark transport returned a non-object response; no automatic retry'
    if 'error' not in response:
        return None
    error = response['error']
    if isinstance(error, str):
        return error
    code = str(error.get('code', '')) if isinstance(error, dict) else ''
    if code in ('401', '403') and isinstance(response.get('protection'), dict):
        return 'Benchmark deployment authentication rejected (HTTP ' + code + '); no automatic retry'
    return 'Benchmark transport returned a structured error; no automatic retry'
