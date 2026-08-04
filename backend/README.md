# The Everest Bistro — Backend API

This is the FastAPI backend for The Everest Bistro point-of-sale and kitchen dispatch system. 

## Architectural Philosophy
This project strictly enforces **Separation of Concerns**. 
* **Routers** handle the HTTP lifecycle.
* **Services** contain the core business logic.
* **Models** enforce data integrity via Pydantic.
* **Database** logic is isolated from web transport layers.

## Directory Structure

```text
backend/
├── app/
│   ├── api/                  # The Web Layer
│   │   ├── dependencies.py   # Reusable auth/session checks
│   │   └── routes/           # HTTP endpoints (menu, orders, auth)
│   │
│   ├── core/                 # The System Layer
│   │   ├── config.py         # Loads and validates .env variables
│   │   └── database.py       # Supabase client and connection pooling
│   │
│   ├── models/               # The Data Layer
│   │   ├── domain/           # Internal business logic models
│   │   └── schemas/          # Pydantic schemas for API Request/Responses
│   │
│   ├── services/             # The Business Layer
│   │   ├── order_service.py  # E.g., handles the complex checkout flow
│   │   └── menu_service.py   # E.g., handles fetching the active catalog
│   │
│   └── websockets/           # The Real-Time Layer
│       └── connection_manager.py # Broadcasts tickets to the kitchen panel
│
├── .env                      # Local secrets vault (ignored by git)
├── main.py                   # The application bootstrapper
└── requirements.txt          # Python dependencies
```

## Module Responsibilities (The "Why")

To maintain a scalable and maintainable codebase, we strictly adhere to the Single Responsibility Principle. Here is exactly what goes into each file and why.

### `app/core/` (System Foundation)
*   **`config.py`**: The centralized environment manager. Instead of scattering `os.getenv()` throughout the app, this file loads the `.env` variables using Pydantic Settings. **Why?** It provides "fail-fast" validation. If the app boots up and a required database key is missing, the server crashes immediately with a clear error rather than failing silently halfway through a customer's checkout.
*   **`database.py`**: Instantiates the Supabase client. **Why?** It ensures we create a single, reusable database connection pool when the server starts, rather than opening a brand new connection for every single HTTP request, which would exhaust resources under heavy load.

### `app/models/` (Data Boundaries)
*   **`schemas/` (e.g., `order_schema.py`)**: Pydantic models that define the exact shape of incoming JSON requests and outgoing JSON responses. **Why?** This is your API's bouncer. It automatically validates data types (e.g., ensuring `quantity` is an integer) and generates the OpenAPI documentation for the frontend team. Bad data is rejected before it ever reaches your business logic.
*   **`domain/`**: Internal Python classes used strictly within the backend. **Why?** Sometimes the way data is stored in the database differs from how the frontend needs to see it. Domain models act as the translator between the two.

### `app/services/` (The Brains)
*   **e.g., `order_service.py`, `menu_service.py`**: This is where the actual business logic lives. If you need to calculate proration, check if an item is out of stock, or format a database query, it happens here. **Why?** By keeping business logic out of the web routes, you can trigger the exact same `create_order()` function from an HTTP POST request, a WebSocket message, or an automated background task without rewriting code.

### `app/api/` (The Traffic Cops)
*   **`routes/` (e.g., `orders.py`)**: These files only handle HTTP transport. They receive the request, hand the data to the Service layer, and package the Service layer's return value into an HTTP response. **Why?** It keeps the web layer thin and readable. 
*   **`dependencies.py`**: Reusable security and injection functions (e.g., `verify_jwt_token`, `require_admin_role`). **Why?** Instead of writing security checks inside every single route, you inject these dependencies into the routes that need them, ensuring consistent security across the app.

### `app/websockets/` (Real-Time Communication)
*   **`connection_manager.py`**: Tracks all active WebSocket clients (like iPads in the kitchen). **Why?** When the `order_service` processes a new ticket, it tells this manager to broadcast the JSON payload to all connected kitchen displays simultaneously, keeping the kitchen strictly in sync with the POS.

### `main.py` (The Bootstrapper)
*   This is the entry point of the application. It initializes the FastAPI instance, configures CORS (allowing the Next.js frontend to talk to it), and mounts all the individual routers from the `app/api/routes/` directory into one unified API.