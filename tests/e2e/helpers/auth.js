/**
 * Authenticates against the Sratim server and sets the session cookie in the browser context.
 */
export async function authenticateSession(context, baseURL, credentials = { username: 'admin', password: 'admin' }) {
  const url = new URL(baseURL);
  const hostname = url.hostname;

  try {
    const res = await fetch(`${baseURL}/api/v1/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(credentials),
    });

    if (!res.ok) {
      console.warn(`Login failed with status ${res.status}`);
      return null;
    }

    const data = await res.json();
    if (data.success && data.token) {
      await context.addCookies([
        {
          name: 'session',
          value: data.token,
          domain: hostname,
          path: '/',
          httpOnly: false,
          secure: false,
          sameSite: 'Lax',
        },
      ]);
      return data.token;
    }
  } catch (err) {
    console.warn('Could not authenticate automatically:', err.message);
  }
  return null;
}
