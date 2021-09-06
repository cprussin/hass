;;; hass.el --- Interact with Home Assistant -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "25.1") (request "0.3.3"))
;; Version: 1.1
;; Author: Ben Whitley
;;; Commentary:

;; This mode enables interaction with a Home Assistant instance from within Emacs.
;;
;; See README.org for more information.
;;
;; Homepage: https://github.com/purplg/hass

;;; Code:
(require 'request)

(defgroup hass '()
  "Minor mode for hass."
  :group 'hass
  :prefix "hass-")

(defvar hass-mode-map (make-sparse-keymap)
  "Keymap for hass mode.")


;; Customizable
(defcustom hass-url nil
  "The URL of the Home Assistant instance.
Set this to the URL of the Home Assistant instance you want to
control.  (e.g. https://192.168.1.10:8123)"
  :group 'hass
  :type 'string)

(defcustom hass-apikey nil
  "API key used for Home Assistant queries.
The key generated from the Home Assistant instance used to authorize API
requests"
  :group 'hass
  :type 'string)

(defcustom hass-auto-entities nil
  "A list of tracked Home Assistant entities.
Set this to a list of Home Assistant entity ID strings.  An entity ID looks
something like *switch.bedroom_light*."

  :group 'hass
  :type '(repeat string))

(defcustom hass-auto-query nil
  "Periodically query the state of the configured in HASS-ENTITIES."
  :group 'hass
  :type 'boolean)

(defcustom hass-auto-query-frequency 60
  "Amount of seconds between auto-querying HASS-ENTITIES."
  :group 'hass
  :type 'integer)


;; Hooks
(defvar hass-entity-state-updated-functions nil
 "List of functions called when an entity state changes.
Each function is called with one arguments: the ENTITY-ID of the
entity whose state changed.")

(defvar hass-entity-state-updated-hook nil
 "Hook called after an entity state data was received.")

(defvar hass-service-called-hook nil
 "Hook called after a service has been called.")


;; Internal state
(defvar hass--states '()
  "An alist of entity ids to their last queried states.")

(defvar hass--user-agent "Emacs hass.el"
  "The user-agent sent in API requests to Home Assistant.")

(defvar hass--timer nil
  "Stores a reference to the timer used to periodically update entity state.")

(defvar hass--available-entities nil
  "The entities retrieved from the Home Assistant instance.")

(defvar hass--available-services nil
  "The services retrieved from the Home Assistant instance.")


;; Helper functions
(defun hass--apikey ()
  "Return the effective apikey.
If HASS-APIKEY is a function, execute it to get value.  Otherwise
return HASS-APIKEY as is."
  (if (functionp hass-apikey)
      (funcall hass-apikey)
      hass-apikey))

(defun hass--entity-url (entity-id)
  "Generate entity state endpoint URLs.
ENTITY-ID is a string of the entities ID."
  (format "%s/%s/%s" hass-url "api/states" entity-id))

(defun hass--service-url (service)
  "Generate service endpoint URL.
SERVICE is a string of the service to call."
  (let* ((parts (split-string service "\\."))
         (domain (pop parts))
         (service (pop parts)))
    (format "%s/api/services/%s/%s" hass-url domain service)))

(defun hass--domain-of-entity (entity-id)
  "Convert an ENTITY-ID to its respective domain."
  (car (split-string entity-id "\\.")))

(defun hass--services-for-entity (entity-id)
  "Return the services available for an ENTITY-ID."
  (cdr (assoc (hass--domain-of-entity entity-id) hass--available-services)))

(defun hass-state-of (entity-id)
  "Return the last known state of ENTITY-ID."
  (cdr (assoc entity-id hass--states)))


;; API parsing
(defun hass--parse-all-entities (entities)
  "Convert entity state data into a list of available entities.
ENTITIES is the data returned from the `/api/states' endpoint."
  (delq nil (mapcar (lambda (entity) (hass--parse-entity entity))
                    entities)))

(defun hass--parse-entity (entity-state)
  "Convert an entity's state data into its entity-id.
ENTITY-STATE is an individual entity state data return from the
`/api/states' endpoint.

Only returns entities that have callable services available."
  (let ((entity-id (cdr (car entity-state))))
    (when (hass--services-for-entity entity-id)
      entity-id)))

(defun hass--parse-all-domains (domains)
  "Collect DOMAINS into an alist of their associated services.
DOMAINS is the data returned from the `/api/services' endpoint."
  (mapcar #'hass--parse-domain domains))

(defun hass--parse-domain (domain)
  "Convert DOMAIN into cons cell of its available list of services.
DOMAIN is a single domain return from the `/api/services'
endpoint."
  (cons (cdr (assoc 'domain domain))
        (hass--parse-services (cdr (assoc 'services domain)))))
  
(defun hass--parse-services (services)
  "Flattens the SERVICES return from `/api/services' endpoint to just the service name."
  (mapcar (lambda (service) (car service))
          services))


;; Request Callbacks
(defun hass--get-entities-result (entities)
  "Callback when states of all ENTITIES is received from API."
  (setq hass--available-entities (hass--parse-all-entities entities)))

(defun hass--get-available-services-result (domains)
  "Callback when all service information is received from API.
DOMAINS is the response from the `/api/services' endpoint which
returns a list of domains and their available services."
  (setq hass--available-services (hass--parse-all-domains domains)))

(defun hass--query-entity-result (entity-id state)
  "Callback when an entity state data is received from API.
ENTITY-ID is the id of the entity that has STATE."
  (let ((previous-state (hass-state-of entity-id)))
    (setf (alist-get entity-id hass--states nil nil 'string-match-p) state)
    (unless (equal previous-state state)
      (run-hook-with-args 'hass-entity-state-updated-functions entity-id)))
  (run-hooks 'hass-entity-state-updated-hook))

(defun hass--call-service-result (entity-id state)
  "Callback when a successful service request is received from API.
ENTITY-ID is the id of the entity that was affected and now has STATE."
  (setf (alist-get entity-id hass--states nil nil 'string-match-p) state)
  (run-hooks 'hass-service-called-hook))

(cl-defun hass--request-error (&key error-thrown &allow-other-keys)
  "Error handler for invalid requests.
ERROR-THROWN is the error thrown from the request.el request."

  (let ((error (cdr error-thrown)))
    (cond ((string= error "exited abnormally with code 7\n")
           (hass-mode 0)
           (user-error "Hass-mode: No Home Assistant instance detected at url: %s" hass-url))
          ((string= error "exited abnormally with code 35\n") 
           (hass-mode 0)
           (user-error "Hass-mode: Did you mean to use HTTP instead of HTTPS for url %s?" hass-url))
          ((error "Hass-mode: unknown error: %S" error-thrown)))))


;; Requests
(defun hass--request (type url &optional success payload)
  "Function to reduce a lot of boilerplate when making a request.
TYPE is a string of the type of request to make. For example, `\"GET\"'.

URL is a string of URL of the request.

SUCCESS is a callback function for when the request successful
completed.

PAYLOAD is contents the body of the request."
  (request url
       :sync nil
       :type type
       :headers `(("User-Agent" . hass--user-agent)
                  ("Authorization" . ,(concat "Bearer " (hass--apikey)))
                  ("Content-Type" . "application/json"))
       :data payload
       :parser #'json-read
       :error #'hass--request-error
       :success success))

(defun hass--get-available-entities ()
  "Retrieve the available entities from the Home Assistant instance.
Makes a request to `/api/states' but drops everything except an
list of entity-ids."
  (hass--request "GET" (concat hass-url "/api/states")
     (cl-function
       (lambda (&key response &allow-other-keys)
         (let ((data (request-response-data response)))
           (hass--get-entities-result data))))))

(defun hass--get-available-services ()
  "Retrieve the available services from the Home Assistant instance."
  (hass--request "GET" (concat hass-url "/api/services")
     (cl-function
       (lambda (&key response &allow-other-keys)
         (let ((data (request-response-data response)))
           (hass--get-available-services-result data))))))

(defun hass--get-entity-state (entity-id)
  "Retrieve the current state of ENTITY-ID from the Home Assistant server.
This function is just for sending the actual API request."
  (hass--request "GET" (hass--entity-url entity-id)
    (cl-function
      (lambda (&key response &allow-other-keys)
        (let ((data (request-response-data response)))
          (hass--query-entity-result entity-id (cdr (assoc 'state data))))))))

(defun hass--call-service (service payload &optional success-callback)
  "Call service SERVICE for ENTITY-ID on the Home Assistant server.
This function is just for building and sending the actual API request.

DOMAIN is a string for the domain in Home Assistant this service is apart of.

SERVICE is a string of the Home Assistance service in DOMAIN that
is being called.

ENTITY-ID is a string of the entity_id in Home Assistant."
  (hass--request "POST"
                 (hass--service-url service)
                 success-callback
                 payload))

(defun hass-call-service (entity-id service)
  "Call service for an entity on Home Assistant.
If called interactively, prompt the user for an ENTITY-ID and
SERVICE to call.

This will send an API request to the url configure in `hass-url'.

ENTITY-ID is a string of the entity id in Home Assistant you want
to call the service on.  (e.g. `\"switch.kitchen_light\"').

SERVICE is the service you want to call on ENTITY-ID.  (e.g. `\"turn_off\"')"
  (interactive
    (let ((entity (completing-read "Entity: " hass--available-entities nil t)))
      (list entity
            (format "%s.%s"
                    (hass--domain-of-entity entity)
                    (completing-read (format "%s: " entity) (hass--services-for-entity entity) nil t)))))
  (hass-call-service-with-payload
   service
   (format "{\"entity_id\": \"%s\"}" entity-id)
   (lambda (&rest _) (hass--get-entity-state entity-id))))

(defun hass-call-service-with-payload (service payload &optional callback)
  "Call service with a custom payload on Home Assistant.
This will send an API request to the url configure in `hass-url'.

SERVICE is a string of the Home Assistant service to be called.

PAYLOAD is a JSON-encoded string of the payload to be sent with SERVICE.

CALLBACK is an optional function to be called after the service call is sent."
  (hass--call-service
   service
   payload
   (lambda (&rest _) (run-hooks 'hass-service-called-hook) (when callback (funcall callback)))))


;; Auto query
(defun hass-auto-query-toggle ()
  "Toggle querying Home Assistant periodically.
Auto-querying is a way to periodically query the state of
entities you want to hook into to capture when their state
changes.

Use the variable `hass-auto-query-frequency' to change
the frequency (in seconds) hass-mode should query the Home
Assistant instance.

Use the variable `hass-auto-entities' to set which entities you want
to query automatically."
  (interactive)
  (if hass-auto-query
    (hass-auto-query-disable)
    (hass-auto-query-enable)))

(defun hass-auto-query-enable ()
  "Enable auto-query."
  (unless hass-mode (user-error "Hass-mode must be enabled to use this feature"))
  (when hass--timer (hass--auto-query-cancel))
  (setq hass--timer (run-with-timer nil hass-auto-query-frequency 'hass-query-all-entities))
  (setq hass-auto-query t))

(defun hass-auto-query-disable ()
  "Disable auto-query."
  (hass--auto-query-cancel)
  (setq hass-auto-query nil))

(defun hass--auto-query-cancel ()
  "Cancel auto-query without disabling it."
  (when hass--timer
    (cancel-timer hass--timer)
    (setq hass--timer nil)))

(defun hass-query-all-entities ()
  "Update the current state all of the registered entities."
  (interactive)
  (dolist (entity hass-auto-entities)
    (hass--get-entity-state entity)))


;;;###autoload
(define-minor-mode hass-mode
  "Toggle hass-mode.
Key bindings:
\\{hass-mode-map}"
  :lighter nil
  :group 'hass
  :global t
  (when hass-mode
      (unless (equal (type-of (hass--apikey)) 'string)
          (hass-mode 0)
          (user-error "HASS-APIKEY must be set to use hass-mode"))
      (unless (equal (type-of hass-url) 'string)
          (hass-mode 0)
          (user-error "HASS-URL must be set to use hass-mode"))
      (when hass-auto-query (hass-auto-query-enable))
      (hass--get-available-entities)
      (hass--get-available-services))
  (unless hass-mode (hass--auto-query-cancel)))

(provide 'hass)

;;; hass.el ends here
