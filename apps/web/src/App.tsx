import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider } from "@tanstack/react-router";
import { ServicesProvider, type Services } from "./services";
import type { AppRouter } from "./router";

export function App({ services, router }: { services: Services; router: AppRouter }) {
  return (
    <ServicesProvider services={services}>
      <QueryClientProvider client={services.queryClient}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </ServicesProvider>
  );
}
