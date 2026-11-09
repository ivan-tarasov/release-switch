<?php

if (parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) !== '/') {
    http_response_code(404);
    exit;
}

header('X-App-Version: ' . trim((string) @file_get_contents(__DIR__ . '/../RELEASE')));
echo file_get_contents(__DIR__ . '/../data/note.txt');
