"""
NBA Team Stats API — the compliant tenant app.

This service is deliberately squeaky-clean so it passes every Kyverno policy
in this demo: labeled, pinned image tag, resource requests/limits, runs as a
non-root user, and (after `scripts/03-deploy-app.sh` runs) ships with a
Cosign signature.
"""

import logging
import os

from flask import Flask, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("team-stats-api")

VERSION = os.environ.get("APP_VERSION", "v1")

TEAMS = [
    {"id": 1, "name": "Lakers",   "conference": "West", "wins": 48, "losses": 22, "streak": "W4"},
    {"id": 2, "name": "Celtics",  "conference": "East", "wins": 55, "losses": 15, "streak": "W7"},
    {"id": 3, "name": "Warriors", "conference": "West", "wins": 42, "losses": 28, "streak": "L2"},
    {"id": 4, "name": "Nuggets",  "conference": "West", "wins": 50, "losses": 20, "streak": "W3"},
    {"id": 5, "name": "Bucks",    "conference": "East", "wins": 46, "losses": 24, "streak": "W1"},
    {"id": 6, "name": "Heat",     "conference": "East", "wins": 40, "losses": 30, "streak": "L1"},
]


@app.route("/")
def index():
    return jsonify({
        "service": "team-stats-api",
        "version": VERSION,
        "description": "NBA Team Stats — admitted to the cluster by Kyverno",
        "endpoints": [
            "GET /teams — all teams",
            "GET /teams/<id> — single team",
            "GET /standings/<conference> — conference standings (East|West)",
            "GET /health — health check",
        ],
    })


@app.route("/teams")
def teams():
    return jsonify({"teams": TEAMS, "count": len(TEAMS)})


@app.route("/teams/<int:team_id>")
def team(team_id):
    match = next((t for t in TEAMS if t["id"] == team_id), None)
    if not match:
        return jsonify({"error": "team not found"}), 404
    return jsonify(match)


@app.route("/standings/<conference>")
def standings(conference):
    conf = conference.capitalize()
    if conf not in ("East", "West"):
        return jsonify({"error": "conference must be East or West"}), 400
    ranked = sorted(
        (t for t in TEAMS if t["conference"] == conf),
        key=lambda t: t["wins"],
        reverse=True,
    )
    return jsonify({"conference": conf, "standings": ranked})


@app.route("/health")
def health():
    return jsonify({"status": "ok", "version": VERSION})


if __name__ == "__main__":
    logger.info("team-stats-api %s starting on :8080", VERSION)
    app.run(host="0.0.0.0", port=8080)
