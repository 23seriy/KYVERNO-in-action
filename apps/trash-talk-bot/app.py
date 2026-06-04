"""
Trash Talk Bot — the rogue workload.

Used as the base image for every `k8s/bad-pods/*.yaml` manifest. Each variant
of the manifest tries to violate a different Kyverno policy (runs as root,
uses :latest, skips labels, mounts hostPath, etc.) so the demo can show the
admission webhook reject it.

The app itself is trivial — it just shouts trash talk on a loop and exposes
a /health endpoint, so when one of the rogue manifests *does* get admitted
(the baseline scenario) you can still see it running.
"""

import logging
import os
import random
import threading
import time

from flask import Flask, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("trash-talk-bot")

LINES = [
    "Your defense is softer than airport pillows.",
    "Bro shoots free throws like he's mad at the rim.",
    "Y'all play like the shot clock is a suggestion.",
    "That crossover broke ankles AND lease agreements.",
    "Defense optional in this arena, apparently.",
    "Caught more air than the HVAC.",
]


def shout_forever():
    while True:
        logger.info("TRASH TALK: %s", random.choice(LINES))
        time.sleep(5)


@app.route("/")
def index():
    return jsonify({
        "service": "trash-talk-bot",
        "version": os.environ.get("APP_VERSION", "v1"),
        "description": "Loud and unwelcome. Used to demonstrate Kyverno rejections.",
    })


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    threading.Thread(target=shout_forever, daemon=True).start()
    logger.info("trash-talk-bot starting on :8080")
    app.run(host="0.0.0.0", port=8080)
