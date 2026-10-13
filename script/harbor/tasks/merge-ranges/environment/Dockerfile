FROM python:3.13.7-slim-bookworm

RUN useradd --create-home --uid 10001 sumika && mkdir /app && chown sumika:sumika /app
WORKDIR /app
COPY --chown=sumika:sumika ranges.py test_ranges.py /app/
USER sumika
