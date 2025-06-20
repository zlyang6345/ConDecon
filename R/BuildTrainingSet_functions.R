#' Build the training dataset
#' @description Use a Gaussian mixture model (with random parameters)
#' to generate a traning dataset from the reference single-cell data
#' @importFrom stats dist uniroot
#' @import Matrix
#' @param count single-cell count matrix (features x cells)
#' @param latent matrix of single-cell latent space (cells x dims)
#' @param max.iter size of the training dataset (default = 10,000)
#' @param max.cent max number of centers in the Gaussian (default = 5)
#' @param step manually parallelize building the training dataset
#' @param dims number of dimensions from latent (default = ncol(latent))
#' @param min.cent min number of centers in the Gaussian (default = 1)
#' @param n number of cells to be chosen to create the training dataset (default
#' is half the number of cells in the count matrix)
#' @param sigma_min_cells min number of cells that should be captured by the standard
#' deviation of the Gaussian
#' @param sigma_max_cells max number of cells that should be captured by the standard
#' deviation of the Gaussian
#' @param verbose logical indicating whether to print progress (default = TRUE)
#'
#' @return ConDecon object with training data
#' @export
#'
#' @examples
#' data(counts_gps)
#' data(latent_gps)
#'
#' # For this example, we will reduce the training size to max.iter = 50 to reduce run time
#' TrainingSet = BuildTrainingSet(count = counts_gps, latent = latent_gps, max.iter = 50)
BuildTrainingSet <- function(count,
                             latent,
                             max.iter = 5000,
                             max.cent = 5,
                             step = ifelse(max.iter <= 10000, max.iter, 10000),
                             dims = 10,
                             min.cent = 1,
                             n = round(ncol(count)/2),
                             sigma_min_cells = NULL,
                             sigma_max_cells = NULL,
                             verbose = FALSE){

  output <- NULL
  output <- vector(mode="list", length=0)

  tot.cells <- ncol(count)
  
  # Calculate the Euclidean distance between different cells in latent space. 
  output$TrainingSet$latent_distance <- as.matrix(stats::dist(latent[,1:dims,drop=F]))
  output$TrainingSet$dims <- dims

  N <- ncol(count)

  ### FIND SIGMA VALUES ###

  # Find sigma min
  if(is.null(sigma_min_cells)){
    N_min <- max(20, round(N/100))
  } else{
    N_min <- round(sigma_min_cells)
  }

  # Find sigma max
  if(is.null(sigma_max_cells)){
    N_max <- ifelse(round(N/5)<N_min, N, round(N/5))
  } else{
    N_max <- round(sigma_max_cells)
  }
  
  k <- N_max
  # For each row (each point), it finds the indices of the k nearest neighbors using the precomputed distance matrix.
  knn <- t(apply(output$TrainingSet$latent_distance, 1, function(i){
    order(i, decreasing = F)[1:k]
  }))
  # For each point, it extracts the actual distances to those neighbors.
  knn_dist <- t(apply(knn, 1, function(i){
    output$TrainingSet$latent_distance[i[1],i]
  }))
  k_dist <- colMeans(knn_dist) # The average neighbor distance for each point.
  
  error.sigma.max <- FALSE
  # The function uniroot searches the interval from lower to upper for a root (i.e., zero) of the function f with respect to its first argument.
  # x_i=seq(0, max(k_dist), by = 0.01) is the range to do the integral
  # lower=min(knn_dist[knn_dist>0]), upper=max(knn_dist) is the range of sigma to find root 
  tryCatch({ sigma_max <- stats::uniroot(Find_Sigma, x_i=seq(0, max(k_dist), by = 0.01), width = 0.01, 
                                         lower=min(knn_dist[knn_dist>0]), upper=max(knn_dist))$root }, 
            error = function(e) {error.sigma.max <<- TRUE})
  # sigma_max <- uniroot(Find_Sigma, x_i=seq(0,max(k_dist), by = 0.01), width = 0.01, lower=min(knn_dist[knn_dist>0]), upper=max(knn_dist))$root

  # Find sigma min
  k <- N_min
  knn <- t(apply(output$TrainingSet$latent_distance, 1, function(i){
    order(i, decreasing = F)[1:k]
  }))
  knn_dist <- t(apply(knn, 1, function(i){
    output$TrainingSet$latent_distance[i[1],i]
  }))
  k_dist <- colMeans(knn_dist)
  # sigma_min <- uniroot(Find_Sigma, x_i=seq(0,max(k_dist), by = 0.01), width = 0.01, lower=min(knn_dist[knn_dist>0]), upper=max(knn_dist))$root
  error.sigma.min <- FALSE
  tryCatch({ sigma_min <- uniroot(Find_Sigma, x_i=seq(0, max(k_dist), by = 0.01), width = 0.01, 
                                   lower=min(knn_dist[knn_dist>0]), upper=max(knn_dist))$root }, 
            error = function(e) {error.sigma.min <<- TRUE})
  
  if(error.sigma.max & error.sigma.min){
    stop("Could not solve for sigma\nTry increasing sigma_max_cells and/or sigma_min_cells\nor decreasing the number of dimensions in the latent space to decrease sparsity")
    return(NULL)
  } else if(error.sigma.min & error.sigma.max == FALSE){
    sigma_min = sigma_max/5
  } else if(error.sigma.max & error.sigma.min == FALSE){
    sigma_max = sigma_min*5
  }

  ### SELECT TRAINING PARAMETERS ###
  # Create a matrix called parameters that will store all the info for each synthetic training set
  # (i.e., each simulated Gaussian mixture).
  #  nrow = max.iter: one row per training example you’re generating.
  #  ncol = 1 + max.cent * 3: enough columns to store:
  #  1 for the number of centers in the GMM (num.centers)
  # max.cent for the center indices (center.1, center.2, ...)
  # max.cent for the sigmas (sigma.1, sigma.2, ...)
  # max.cent for the mixing weights (mix.1, mix.2, ...)
  # list(
  #   NULL,
  #   c("num.centers", "center.1", "center.2", ..., "sigma.1", ..., "mix.1", ...)
  # )
  output$TrainingSet$parameters <- matrix(0, ncol = (1+max.cent*3), nrow = max.iter, dimnames =
                                list(NULL, c("num.centers", paste0("center.",1:max.cent),
                                            paste0("sigma.", 1:max.cent), paste0("mix.", 1:max.cent))))

  # Randomly choose the parameters of a Gaussian mixture model for each training set
  ## Choose number of centers
  output$TrainingSet$parameters[,1] <- sample(min.cent:max.cent, max.iter, replace = TRUE)

  ## Choose centers, sigma, and constant
  ## Find the cell probabilities
  # This is the matrix to store the p-vectors
  # Total number of cells * max iterations(# of data points)
  output$TrainingSet$cell.prob <- matrix(0, ncol = max.iter, nrow = tot.cells)
  
  for(i in 1:max.iter){

    # Choose which cells will be the centers
    output$TrainingSet$parameters[i, 2:(1+output$TrainingSet$parameters[i,1])] <-
      sample(1:tot.cells, output$TrainingSet$parameters[i,1], replace = FALSE)
    
    # Choose sigma
    # 2 + max.cent is the first column index of sigma.1
    # 1 + max.cent + output$TrainingSet$parameters[i, 1] is the last index to write to, based on how many centers are used in row i.
    output$TrainingSet$parameters[i,(2+max.cent):(1+max.cent+output$TrainingSet$parameters[i,1])] <-
      sample(10^seq(log10(sigma_min), # Logarithmic spacing cause linear spacing would put too much emphasis on large values 
                    log10(sigma_max), # Logarithmic spacing ensures even sampling across multiplicative scales 
                    by = 0.0001),  # a sequence
             output$TrainingSet$parameters[i,1], # pick n samples from the sequence 
             replace=TRUE)
    
    # Choose mixture between [1:100]
    mixture <- sample(1:100, output$TrainingSet$parameters[i,1], replace=TRUE)
    output$TrainingSet$parameters[i, (2+max.cent*2):(1+max.cent*2+output$TrainingSet$parameters[i,1])] <- mixture/sum(mixture)

    # Cell Prob
    output$TrainingSet$cell.prob[,i] <- CellProb(parameters = output$TrainingSet$parameters[i,], 
                                                 latent_distance = output$TrainingSet$latent_distance,
                                                 max.cent = max.cent)
  }
  gc(verbose = FALSE)

  pick.cells <- PickCells(max.iter, step, output$TrainingSet$cell.prob, max.cent, tot.cells, n, verbose)
  gc(verbose = FALSE)

  #Aggregate single-cell expression weighted by GMM to create synthetic bulk
  output$TrainingSet$synthetic_bulk <- BulkCells(pick.cells, max.iter, step, max.cent, tot.cells, n, count, verbose)
  return(output)
}

#' Find sigma
#' @param sigma variable
#' @param x_i range of sigma values
#' @param width standard deviation of Gaussian
#' The integral is approximated by Riemann Sum: 
#' ∑_i f(x_i)⋅width
#' 
#' @return Sigma value
Find_Sigma <- function(sigma, x_i, width){
  sum( (1/(sqrt(2*pi)*sigma)) * exp(-(x_i)^2/(2*sigma^2)) )*width-0.5
}

#' Calculate cell probability
#' @description  Calculate the probability of each cell based on a Gaussian distribution
#'
#' @param parameters Parameters for the Gaussian dist
#' @param latent_distance Pairwise distance matrix for each cell in the latent space
#' @param max.cent Maximum number of Gaussian centers
#'
#' @return Numeric vector with an assigned prob for each cell
CellProb <- function(parameters, latent_distance, max.cent){
  
  num.cent <- parameters[1]
  selected_centers <- parameters[2 : (1 + num.cent)]                    # indices of centers
  sigmas <- parameters[(2 + max.cent) : (1 + max.cent + num.cent)]      # std deviations σ
  weights <- parameters[(2 + 2*max.cent) : (1 + 2*max.cent + num.cent)] # mixing weights
  
  # g.mix.model n_cells * n_centers 
  # entry represents the probability that the cell comes from that center
  g.mix.model <- t( 
                    (weights / (sqrt(2*pi)*sigmas)) * 
                     exp(-1 * t(latent_distance[, selected_centers])^2 / (2*sigmas^2))
                  )
  
  # the probability of each cell. 
  return(rowSums(g.mix.model)/sum(rowSums(g.mix.model)))
}

#' Pick cells based on the Gaussian kernel
#' @param max.iter Size of the training data
#' @param step Manual threading; number of calculations to do simultaneously
#' @param cell.prob Cell probability distributions (matrix)
#' @param max.cent Maximum number of Gaussian centers
#' @param tot.cells Total number of cells in the single-cell data
#' @param n Number of cells to select and aggregate for each simulated bulk sample
#' @param verbose Whether to print (verbose = FALSE)
#'
#' @return Matrix of with cells selected to be in each bulk sample
PickCells <- function(max.iter, step, cell.prob, max.cent, tot.cells, n, verbose){
  # if(verbose == TRUE){
  #   message("PickCells")
  # }

  starting <- 1
  pick.cells <- NULL
  
  if ((max.iter/step) == round(max.iter/step)){
    for(i in seq(from = step, to = max.iter, by=step)){
      pick_cells <- lapply(starting:i, BulkCells_subfxn, cell.prob=cell.prob,
                           tot.cells=tot.cells, n=n)
      pick.cells <- rbind(pick.cells, do.call(rbind, pick_cells))
      starting <- i+1
    }
  } else if((max.iter/step) != round(max.iter/step)){
    for(i in c(seq(from = step, to = max.iter,by=step), max.iter)){
      pick_cells <- lapply(starting:i,BulkCells_subfxn,cell.prob=cell.prob,
                           tot.cells=tot.cells,n=n)
      pick.cells <- rbind(pick.cells, do.call(rbind, pick_cells))
      starting <- i+1
    }
  }
  return(pick.cells)
}

#' Sample cells
#' @param i Indicator for the cell probability distribution
#' @param cell.prob Cell probability distributions (matrix)
#' @param tot.cells Number of cells to select and aggregate for each simulated bulk sample
#' @param n Total number of cells in the single-cell data
#'
#' @return Cells selected to be in each bulk sample
BulkCells_subfxn <- function(i, cell.prob, tot.cells, n){
  return(sample(1:tot.cells, n, replace = TRUE, prob = cell.prob[,i]))
}

#' Aggregate cells in bulk data based on the Gaussian kernal
#' @importFrom plyr count
#' @import Matrix
#' @importFrom tidyr gather
#' @param pick.cells Matrix of with cells selected to be in each bulk sample
#' @param max.iter Size of the training data
#' @param step Manual threading; number of calculations to do simultaneously
#' @param max.cent Maximum number of Gaussian centers
#' @param tot.cells Number of cells to select and aggregate for each simulated bulk sample
#' @param n Total number of cells in the single-cell data
#' @param count Matrix of single-cell count data
#' @param verbose Whether to print (verbose = FALSE)
#'
#' @return Matrix with simulated bulk data
BulkCells <- function(pick.cells, max.iter, step, max.cent, tot.cells, n, count, verbose){
  # if(verbose == TRUE){
  #   message("Bulk Cells")
  # }

  starting <- 1
  bulk.coef <- NULL
  bulk <- NULL
  if ((max.iter/step) == round(max.iter/step)){
    row.names(pick.cells) <- rep(1:step,(max.iter/step))
    for(i in seq(from = step, to = max.iter, by=step)){
      count.cells <- plyr::count(tidyr::gather(as.data.frame(t(pick.cells[starting:i,]))))
      gc(verbose = F)
      bulk_nn <- count %*% Matrix::sparseMatrix(i=count.cells[,2], j=as.numeric(count.cells[,1]),
                                        x=count.cells[,3], dims = c(tot.cells,step))
      bulk_nn1 <- t(t(bulk_nn)/colSums(bulk_nn))*1000000
      bulk <- c(bulk, bulk_nn1)
      rm(bulk_nn)
      starting <- i+1
    }
  } else if((max.iter/step) != round(max.iter/step)){
    row.names(pick.cells) <- c(rep(1:step,floor(max.iter/step)),1:(max.iter %% step))
    for(i in c(seq(from = step, to = max.iter,by=step), max.iter)){
      count.cells <- plyr::count(tidyr::gather(as.data.frame(t(pick.cells[starting:i,]))))
      gc(verbose = F)
      ##Change to the crossprod function
      bulk_nn <- count %*% Matrix::sparseMatrix(i=count.cells[,2], j=as.numeric(count.cells[,1]),
                                        x=count.cells[,3], dims = c(tot.cells,length(starting:i)))
      bulk_nn1 <- t(t(bulk_nn)/colSums(bulk_nn))*1000000
      bulk <- c(bulk, bulk_nn1)
      rm(bulk_nn)
      starting <- i+1
    }
  }
  bulk <- do.call(cbind, bulk)
  bulk <- as.matrix(bulk)
  return(bulk)
}
