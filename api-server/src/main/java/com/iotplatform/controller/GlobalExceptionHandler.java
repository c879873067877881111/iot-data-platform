package com.iotplatform.controller;

import org.springframework.http.HttpStatus;
import org.springframework.http.ProblemDetail;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.server.ResponseStatusException;

import java.net.URI;

@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(ResponseStatusException.class)
    public ProblemDetail handleResponseStatus(ResponseStatusException e) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(e.getStatusCode(), e.getReason());
        problem.setTitle(e.getStatusCode().toString());
        return problem;
    }

    @ExceptionHandler(IllegalArgumentException.class)
    public ProblemDetail handleBadRequest(IllegalArgumentException e) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, e.getMessage());
        problem.setTitle("Bad Request");
        return problem;
    }

    @ExceptionHandler(Exception.class)
    public ProblemDetail handleException(Exception e) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(HttpStatus.INTERNAL_SERVER_ERROR, "Internal server error");
        problem.setTitle("Internal Server Error");
        return problem;
    }
}
