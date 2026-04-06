<%@ page contentType="application/json; charset=UTF-8" %>
<%
    String path = request.getServletPath();
    if ("/health".equals(path) || request.getPathInfo() == null) {
        response.setContentType("application/json");
        out.print("{\"status\":\"ok\",\"service\":\"java-tomcat-app\",\"version\":\"1.0\"}");
    } else {
        out.print("{\"status\":\"ok\",\"service\":\"java-tomcat-app\"}");
    }
%>
