// Express.js route handlers
app.get('/users/:id', async (req, res, next) => {
  try {
    const user = await User.findById(req.params.id);
    if (!user) return res.status(404).json({ error: 'Not found' });
    res.json({ data: user });
  } catch (err) {
    next(err);
  }
});

app.post('/api/login', validateRequest, async (req, res) => {
  const { email, password } = req.body;
  const token = await authService.login(email, password);
  res.cookie('token', token, { httpOnly: true }).json({ success: true });
});
