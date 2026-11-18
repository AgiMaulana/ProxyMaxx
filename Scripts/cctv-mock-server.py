#!/usr/bin/env python3
"""
Mock multi-camera CCTV MJPEG streaming server for ProxyMaxx Phase 7 manual gate.

Serves:
  - GET /          : Multi-camera grid dashboard HTML
  - GET /stream    : Multipart/x-mixed-replace MJPEG stream (10-15 fps per camera)

Usage:
  python3 Scripts/cctv-mock-server.py [--port 8088] [--fps 10]
"""

import argparse
import os
import sys
import time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Valid 64x64 baseline JPEG frame
SAMPLE_JPEG = bytes([
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48,
    0x00, 0x48, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43, 0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08,
    0x07, 0x07, 0x07, 0x09, 0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
    0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20, 0x24, 0x2E, 0x27, 0x20,
    0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29, 0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27,
    0x39, 0x3D, 0x38, 0x32, 0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x40,
    0x00, 0x40, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00, 0x01, 0x05, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04,
    0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F,
    0x00, 0xBF, 0xFF, 0xD9
])

class CCTVHandler(BaseHTTPRequestHandler):
    fps = 10

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path in ('/', '/index.html'):
            self.serve_dashboard()
        elif parsed.path == '/stream':
            self.serve_mjpeg_stream()
        else:
            self.send_error(404, "Not Found")

    def serve_dashboard(self):
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        html_path = os.path.join(root, "docs", "perf", "cctv-dashboard.html")
        try:
            with open(html_path, "rb") as f:
                content = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except Exception as e:
            self.send_error(500, f"Error loading dashboard: {e}")

    def serve_mjpeg_stream(self):
        boundary = "frame"
        self.send_response(200)
        self.send_header("Content-Type", f"multipart/x-mixed-replace; boundary=--{boundary}")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.end_headers()

        delay = 1.0 / max(1, self.fps)
        frame_index = 0

        try:
            while True:
                frame_data = SAMPLE_JPEG
                header = (
                    f"--{boundary}\r\n"
                    f"Content-Type: image/jpeg\r\n"
                    f"Content-Length: {len(frame_data)}\r\n"
                    f"X-Frame-Index: {frame_index}\r\n\r\n"
                ).encode('utf-8')

                self.wfile.write(header)
                self.wfile.write(frame_data)
                self.wfile.write(b"\r\n")
                self.wfile.flush()

                frame_index += 1
                time.sleep(delay)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        # Silence per-request streaming log spam
        return

def main():
    parser = argparse.ArgumentParser(description="ProxyMaxx Mock CCTV Streaming Server")
    parser.add_argument("--port", type=int, default=8088, help="Port to listen on (default: 8088)")
    parser.add_argument("--fps", type=int, default=10, help="Frames per second per stream (default: 10)")
    args = parser.parse_args()

    CCTVHandler.fps = args.fps
    server = HTTPServer(("127.0.0.1", args.port), CCTVHandler)
    print(f"📹 CCTV Mock Server listening on http://127.0.0.1:{args.port}/")
    print(f"   Dashboard URL: http://127.0.0.1:{args.port}/")
    print(f"   Streaming at {args.fps} fps per camera. Press Ctrl+C to stop.")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down CCTV server.")
        server.server_close()

if __name__ == "__main__":
    main()
