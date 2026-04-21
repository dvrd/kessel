// Real-world class patterns
class BaseController {
  constructor(service) {
    this.service = service;
    this.logger = console;
  }
  
  async handleRequest(req, res) {
    try {
      const result = await this.service.process(req.body);
      return res.json({ success: true, data: result });
    } catch (error) {
      this.logger.error(error);
      return res.status(500).json({ error: 'Internal error' });
    }
  }
}

class UserController extends BaseController {
  static validateInput(data) {
    return data && data.email && data.password;
  }
  
  #privateCache = new Map();
}
