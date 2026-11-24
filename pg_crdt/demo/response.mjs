// Firewall responses may be HTML or plain text, so handle 429 before JSON.
export async function readCounterResponse(response) {
  if (response.status === 429) {
    throw new Error('Too many demo requests. Wait a minute before trying again. Your local edits are safe.');
  }
  const body = await response.json();
  if (!response.ok) throw new Error(body.error ?? 'The demo request failed. Try again.');
  return body;
}
