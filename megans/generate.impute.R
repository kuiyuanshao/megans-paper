pmm <- function(yhatobs, yhatmis, yobs, k) {
  idx <- mice::matchindex(d = yhatobs, t = yhatmis, k = k)
  yobs[idx]
}

create_bfi <- function(data, batch_size, tensor_list){
  n <- ceiling(nrow(data) / batch_size)
  idx <- 1
  batches <- vector("list", n)
  for (i in 1:n){
    if (i == n){
      batch_size <- nrow(data) - batch_size * (n - 1)
    }
    batches[[i]] <- lapply(tensor_list, function(tensor) tensor[idx:(idx + batch_size - 1), , drop = FALSE])
    idx <- idx + batch_size
  }
  return (batches = batches)
}

generateImpute <- function(gnet, m = 5, 
                           data_original, data_info, data_norm, 
                           data_encode, data_training,
                           phase1_vars, phase2_vars,
                           num.normalizing, cat.encoding, 
                           batch_size, device, params,
                           tensor_list, type, log_shift){
  imputed_data_list <- vector("list", m)
  gsample_data_list <- vector("list", m)
  batchforimpute <- create_bfi(data_original, batch_size, tensor_list)
  data_mask <- as.matrix(1 - is.na(data_original))
  
  ub <- sapply(phase2_vars[phase2_vars %in% data_info$num_vars], function(v) max(data_original[[v]], na.rm = T), 
               simplify = TRUE, USE.NAMES = TRUE)
  lb <- sapply(phase2_vars[phase2_vars %in% data_info$num_vars], function(v) min(data_original[[v]], na.rm = T), 
               simplify = TRUE, USE.NAMES = TRUE)
  names(ub) <- phase2_vars[phase2_vars %in% data_info$num_vars]
  names(lb) <- phase2_vars[phase2_vars %in% data_info$num_vars]
  max_attempt <- 15
  
  num_col <- names(data_original) %in% data_info$num_vars
  suppressWarnings(data_original[is.na(data_original)] <- 0)
  
  A_t <- tensor_list[[4]]
  C_t <- tensor_list[[2]]
  
  for (z in 1:m){
    output_list <- vector("list", length(batchforimpute))
    #noise_mat <- NULL
    for (i in 1:length(batchforimpute)){
      batch <- batchforimpute[[i]]
      A <- batch[[4]]
      X <- batch[[3]]
      C <- batch[[2]]

      fakez <- torch_normal(mean = 0, std = 1, 
                            size = c(X$size(1), params$noise_dim))$to(device = device)
      fakez_C <- torch_cat(list(fakez, A, C), dim = 2)
      
      gsample <- gnet(fakez_C)
      gsample <- activation_fun(gsample, data_encode, phase2_vars, 
                                tau = 0.2, hard = F, gen = T)
      gsample <- torch_cat(list(gsample, A, C), dim = 2)
      #noise_mat <- rbind(noise_mat, as.matrix(fakez$detach()$cpu()))
      output_list[[i]] <- as.matrix(gsample$detach()$cpu())
    }
    output_mat <- as.data.frame(do.call(rbind, output_list))
    names(output_mat) <- names(data_training)
    
    denormalize <<- paste("denormalize", num.normalizing, sep = ".")
    decode <<- paste("decode", cat.encoding, sep = ".")
    
    curr_gsample <- do.call(decode, args = list(
      data = output_mat,
      encode_obj = data_encode
    ))
    curr_gsample <- do.call(denormalize, args = list(
      data = curr_gsample,
      num_vars = data_info$num_vars, 
      norm_obj = data_norm
    ))
    #get the original order
    gsamples <- curr_gsample$data
    gsamples <- gsamples[, names(data_original)]
    
    if (type == "mmer"){
      gsamples[, match(phase2_vars[phase2_vars %in% data_info$num_vars], names(gsamples))] <-
        data_original[, match(phase1_vars[phase1_vars %in% data_info$num_vars], names(data_original))] -
        gsamples[, match(phase2_vars[phase2_vars %in% data_info$num_vars], names(gsamples))]
      
      # gsamples[, match((phase2_vars[phase2_vars %in% num_vars]), names(gsamples))] <-
      #   sweep(exp(log(sweep(data_original[, match((phase1_vars[phase1_vars %in% num_vars]),
      #                                             names(data_original))], 2, log_shift, "+")) -
      #               gsamples[, match(phase2_vars[phase2_vars %in% num_vars], names(gsamples))]), 2, log_shift, "-")
    }
    
    # Row-wise acceptance probability
    acc_prob_row <- function(mat, lb, ub, alpha = 1) {
      nr <- nrow(mat)
      UB <- matrix(ub, nr, length(ub), byrow = TRUE)
      LB <- matrix(lb, nr, length(lb), byrow = TRUE)
      span <- matrix((ub - lb) / 2, nr, length(lb), byrow = TRUE)

      hi <- pmax(mat - UB, 0)
      lo <- pmax(LB - mat, 0)
      d <- pmax(hi, lo) / span

      #worst_violation <- apply(d, 1, max) # one value per row
      total_violation <- rowSums(d)
      exp(-alpha * total_violation ^ 2)
    }
    gen_rows <- function(idx_vec){
      n <- length(idx_vec)
      z <- torch_normal(0, 1, size = c(n, params$noise_dim))$to(device = device)
      tmp <- gnet(torch_cat(list(z, A_t[idx_vec,], C_t[idx_vec,]), dim = 2))
      tmp <- activation_fun(tmp, data_encode, phase2_vars, gen = T)
      tmp <- torch_cat(list(tmp, A_t[idx_vec,], C_t[idx_vec,]), dim = 2)
      df <- as.data.frame(as.matrix(tmp$detach()$cpu()))
      names(df) <- names(data_training)

      deco <- do.call(decode, args = list(
        data = df,
        encode_obj = data_encode
      ))
      denorm <- do.call(denormalize, args = list(
        data = deco,
        num_vars = data_info$num_vars,
        norm_obj = data_norm
      ))$data

      denorm <- denorm[, names(data_original)]

      if (type == "mmer"){
        idx_p2 <- match(phase2_vars[phase2_vars %in% data_info$num_vars], names(denorm))
        idx_p1 <- match(phase1_vars[phase1_vars %in% data_info$num_vars], names(data_original))
        denorm[, idx_p2] <- data_original[idx_vec, idx_p1] - denorm[, idx_p2]
      }
      denorm
    }
    phase2_idx <- sort(match(data_info$phase2_vars, names(gsamples)))
    M <- gsamples[, phase2_idx, drop = FALSE]
    phase2_num_idx <- match(data_info$phase2_vars[data_info$phase2_vars %in% data_info$num_vars], colnames(M))
    row_acc <- acc_prob_row(as.matrix(M[, phase2_num_idx]), lb, ub)
    accept_row <- runif(nrow(M)) < row_acc

    iter <- 0L
    repeat {
      if (all(accept_row) || iter >= max_attempt) break
      bad_rows <- which(!accept_row)
      M[bad_rows, ] <- gen_rows(bad_rows)[, phase2_idx]
      # Recompute acceptance
      row_acc <- acc_prob_row(as.matrix(M[, phase2_num_idx]), lb, ub)
      accept_row <- runif(nrow(M)) < row_acc
      iter <- iter + 1L
    }
    gsamples[, phase2_idx] <- M

    
    imputations <- data_original
    # ---- numeric columns: use matrix arithmetic ---
    if (any(num_col)) {
      out_num <- data_mask[, num_col] * as.matrix(data_original[, num_col]) +
        (1 - data_mask[, num_col]) * as.numeric(as.matrix(gsamples[, num_col]))
      imputations[, num_col] <- out_num
    }
    # ---- non-numeric columns (factor / character / etc.) -------------
    if (any(!num_col)) {
      fac_cols <- which(!num_col)
      # add missing levels once per factor column
      for (j in fac_cols) {
        new_lvls <- unique(as.character(gsamples[, j]))
        levels(imputations[[j]]) <- union(levels(imputations[[j]]), new_lvls)
      }
      to_replace <- data_mask[, fac_cols] == 0
      idx <- which(to_replace, arr.ind = TRUE)
      col_ids <- fac_cols[idx[, "col"]]
      
      imputations[cbind(idx[, "row"], col_ids)] <-
        gsamples[cbind(idx[, "row"], col_ids)]
    }
    
    imputed_data_list[[z]] <- imputations
    gsample_data_list[[z]] <- gsamples
  }
  return (list(imputation = imputed_data_list, gsample = gsample_data_list))
}
