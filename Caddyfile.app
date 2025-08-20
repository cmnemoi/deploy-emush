{
    # Global options
    auto_https off
    admin off
    persist_config off
}

:5173 {
    # Root directory for static files
    root * /srv
    
    # Enable file server
    file_server
    
    # Handle SPA routing - serve index.html for all non-file requests
    try_files {path} /index.html
    
    # Security headers
    header {
        X-Frame-Options "SAMEORIGIN"
        X-XSS-Protection "1; mode=block"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer-when-downgrade"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline' https://unpkg.com/@ruffle-rs/ruffle; style-src 'self' 'unsafe-inline'; font-src 'self' data: https:; img-src 'self' data: https: blob:; connect-src 'self' http://api.emush.{$DOMAIN}/ https: wss:; media-src 'self' data: blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'self'; form-action 'self';"
    }
    
    # Cache static assets
    @static {
        path *.js *.css *.png *.jpg *.jpeg *.gif *.ico *.svg *.woff *.woff2 *.ttf *.eot
    }
    header @static {
        Cache-Control "public, max-age=31536000, immutable"
    }
    
    # Cache service worker with shorter expiry
    @sw {
        path /sw.js
    }
    header @sw {
        Cache-Control "public, max-age=3600"
    }
    
    # Health check endpoint
    respond /health "healthy" 200
    
    # Enable compression
    encode gzip zstd
    
    # Hide dotfiles
    @dotfiles {
        path */.*
    }
    respond @dotfiles 404
}
