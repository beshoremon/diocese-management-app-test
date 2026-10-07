module.exports = {
  apps: [
    {
      name: 'webapp',
      script: 'npx',
      args: 'next start -p 3000',
      cwd: '/home/user/webapp',
      env: {
        NODE_ENV: 'production',
        PORT: 3000,
      },
      watch: false,
      instances: 1,
      exec_mode: 'fork',
    },
  ],
};
