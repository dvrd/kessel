// Real API client wrapper
class ApiClient {
  constructor(baseURL, options = {}) {
    this.baseURL = baseURL;
    this.headers = {
      'Content-Type': 'application/json',
      ...options.headers
    };
  }
  
  async request(endpoint, { method = 'GET', body, params } = {}) {
    const url = new URL(endpoint, this.baseURL);
    if (params) Object.entries(params).forEach(([k, v]) => url.searchParams.append(k, v));
    
    const response = await fetch(url, {
      method,
      headers: this.headers,
      body: body ? JSON.stringify(body) : undefined
    });
    
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  }
}

export const api = new ApiClient('/api/v1');
